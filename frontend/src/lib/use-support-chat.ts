import { useCallback, useEffect, useRef, useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import {
  supportApi,
  type ApiSupportConversation,
  type ApiSupportMessage,
} from "@/lib/api-client";
import { openCableConsumer, type CableConsumer, type CableSubscription } from "@/lib/support-cable";
import { useAuth } from "@/lib/use-auth";

export const SUPPORT_CONVERSATION_KEY = ["support", "conversation"] as const;

/**
 * How often the launcher re-checks for staff replies while the panel is shut.
 * Matches the notification bell deliberately — same reasoning, same budget:
 * production runs three request threads in total, and this is competing with
 * registrations and payments.
 */
const BADGE_POLL_MS = 60_000;

/** Backoff between reconnect attempts. Capped so a long outage doesn't strand
 * someone on a ten-minute wait once the server comes back. */
const RECONNECT_BASE_MS = 1_000;
const RECONNECT_MAX_MS = 15_000;

export type ConnectionState = "idle" | "connecting" | "connected" | "reconnecting" | "failed";

/** A message the user has sent but the server hasn't confirmed. */
export interface PendingMessage {
  localId: string;
  body: string;
  failed: boolean;
}

/**
 * Everything the support chat panel needs, and the only place that touches
 * ActionCable.
 *
 * ## Why the socket opens with the panel, not with the session
 *
 * The unread badge comes from a 60-second REST poll, the same mechanism as the
 * header bell. The WebSocket only opens while the panel is actually on screen.
 *
 * That keeps the number of live sockets equal to the number of people actively
 * chatting rather than the number of people logged in, which matters on a
 * single-task deployment, and it means an anonymous or idle visitor never opens
 * one at all. The cost is that a reply arriving while the panel is shut shows up
 * on the badge within a minute rather than instantly — which is exactly the
 * latency budget a badge deserves.
 *
 * ## Why REST is still the source of truth
 *
 * Every deploy severs every socket, so delivery is never guaranteed. On each
 * (re)connect the hook refetches `?after=<last known id>` and merges. The socket
 * is a latency optimisation on top of that, not the transport of record — if it
 * fails permanently, chat degrades to "refresh to see replies" rather than
 * silently losing them.
 */
export function useSupportChat({ open }: { open: boolean }) {
  const { user } = useAuth();
  const queryClient = useQueryClient();
  const enabled = Boolean(user);

  const [messages, setMessages] = useState<ApiSupportMessage[]>([]);
  const [pending, setPending] = useState<PendingMessage[]>([]);
  const [connection, setConnection] = useState<ConnectionState>("idle");
  const [hasMore, setHasMore] = useState(false);
  const [loadingHistory, setLoadingHistory] = useState(false);

  // Read by the socket's reconnect handler, which must see the newest value
  // without being torn down and rebuilt every time a message arrives.
  const latestMessageId = useRef<string | null>(null);
  const consumerRef = useRef<CableConsumer | null>(null);
  const subscriptionRef = useRef<CableSubscription | null>(null);
  const reconnectTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const attemptRef = useRef(0);
  const teardownRef = useRef(false);
  const generationRef = useRef(0);

  /** The badge. Polls only while signed in; stops entirely when signed out. */
  const conversationQuery = useQuery({
    queryKey: SUPPORT_CONVERSATION_KEY,
    queryFn: () => supportApi.conversation(),
    enabled,
    refetchInterval: enabled ? BADGE_POLL_MS : false,
    refetchIntervalInBackground: false,
    staleTime: 30_000,
  });

  const conversation: ApiSupportConversation | null = conversationQuery.data?.conversation ?? null;

  const mergeMessages = useCallback((incoming: ApiSupportMessage[]) => {
    if (incoming.length === 0) return;

    setMessages((current) => {
      // De-duplicated by id because the same message legitimately arrives twice:
      // once over the socket, once from the catch-up fetch after a reconnect
      // that overlapped it.
      const byId = new Map(current.map((m) => [m.id, m]));
      incoming.forEach((m) => byId.set(m.id, m));

      const merged = [...byId.values()].sort((a, b) =>
        a.created_at === b.created_at
          ? a.id.localeCompare(b.id)
          : a.created_at.localeCompare(b.created_at),
      );

      latestMessageId.current = merged.at(-1)?.id ?? null;
      return merged;
    });
  }, []);

  /** Everything the client missed. Called on open and on every reconnect. */
  const catchUp = useCallback(async () => {
    const after = latestMessageId.current;
    const result = await supportApi.messages(after ? { after } : {});

    mergeMessages(result.messages);
    // Only meaningful on a first load; with a cursor `has_more` means "more
    // waiting", which the catch-up loop below handles by simply asking again.
    if (!after) setHasMore(result.has_more);

    queryClient.setQueryData(SUPPORT_CONVERSATION_KEY, { conversation: result.conversation });
  }, [mergeMessages, queryClient]);

  const loadOlder = useCallback(async () => {
    const oldest = messages[0]?.id;
    if (!oldest || loadingHistory) return;

    setLoadingHistory(true);
    try {
      const result = await supportApi.messages({ before: oldest });
      mergeMessages(result.messages);
      setHasMore(result.has_more);
    } finally {
      setLoadingHistory(false);
    }
  }, [messages, loadingHistory, mergeMessages]);

  // ── Socket lifecycle ───────────────────────────────────────────────────────
  useEffect(() => {
    if (!open || !enabled) return;

    teardownRef.current = false;
    attemptRef.current = 0;

    const closeSocket = () => {
      subscriptionRef.current?.unsubscribe();
      consumerRef.current?.disconnect();
      subscriptionRef.current = null;
      consumerRef.current = null;
    };

    const scheduleReconnect = () => {
      if (teardownRef.current) return;

      // Cleared first so two retries can't stack into concurrent connects,
      // each burning its own single-use ticket.
      if (reconnectTimer.current) clearTimeout(reconnectTimer.current);

      const delay = Math.min(RECONNECT_BASE_MS * 2 ** attemptRef.current, RECONNECT_MAX_MS);
      attemptRef.current += 1;
      setConnection("reconnecting");
      reconnectTimer.current = setTimeout(() => void connect(), delay);
    };

    const connect = async () => {
      if (teardownRef.current) return;

      // Bumped per attempt so callbacks from a superseded consumer no-op rather
      // than scheduling a competing retry. See the note in use-support-inbox.ts:
      // relying on ActionCable's unsubscribe-before-disconnect ordering happens
      // to work, but the failure mode is a self-feeding ticket loop.
      const mine = ++generationRef.current;

      // A spent ticket can never be reused, so every attempt starts from a
      // brand new consumer rather than letting ActionCable's own monitor
      // replay a dead URL. See openCableConsumer.
      closeSocket();
      setConnection((s) => (s === "reconnecting" ? s : "connecting"));

      try {
        const consumer = await openCableConsumer();
        if (teardownRef.current || mine !== generationRef.current) {
          consumer.disconnect();
          return;
        }
        consumerRef.current = consumer;

        subscriptionRef.current = consumer.subscriptions.create("ChatChannel", {
          connected() {
            if (mine !== generationRef.current) return;
            attemptRef.current = 0;
            setConnection("connected");
            // Ask for everything missed *after* the socket is live, so nothing
            // slips through the gap between fetching and subscribing.
            void catchUp();
          },
          disconnected() {
            if (mine !== generationRef.current) return;
            scheduleReconnect();
          },
          rejected() {
            if (mine !== generationRef.current) return;
            // Not retryable by reconnecting: the ticket was refused, which
            // means the session is no longer valid.
            setConnection("failed");
          },
          received(data: unknown) {
            if (mine !== generationRef.current) return;
            const payload = data as { message?: ApiSupportMessage; conversation?: ApiSupportConversation };
            if (payload.message) mergeMessages([payload.message]);
            if (payload.conversation) {
              queryClient.setQueryData(SUPPORT_CONVERSATION_KEY, {
                conversation: payload.conversation,
              });
            }
          },
        });
      } catch {
        if (mine !== generationRef.current) return;
        scheduleReconnect();
      }
    };

    // Fetch history immediately rather than waiting for the socket — the panel
    // should show the thread the moment it opens, even on a slow handshake.
    void catchUp();
    void connect();

    return () => {
      teardownRef.current = true;
      if (reconnectTimer.current) clearTimeout(reconnectTimer.current);
      closeSocket();
      setConnection("idle");
    };
    // `catchUp` and `mergeMessages` are stable; re-running this on every
    // message would tear the socket down mid-conversation.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open, enabled]);

  // Opening the panel is reading it. Clears the badge without a separate tap.
  useEffect(() => {
    if (!open || !enabled || !conversation || conversation.unread_count === 0) return;

    void supportApi.markRead().then((result) => {
      queryClient.setQueryData(SUPPORT_CONVERSATION_KEY, { conversation: result.conversation });
    });
  }, [open, enabled, conversation, queryClient]);

  const send = useMutation({
    mutationFn: (body: string) => supportApi.sendMessage(body),
  });

  /**
   * Optimistic, with a visible failed state rather than a silent drop.
   *
   * The pending bubble is keyed on a local id and removed once the server's own
   * message arrives — either from this response or from the socket, whichever
   * lands first, which is why `mergeMessages` de-duplicates.
   */
  const sendMessage = useCallback(
    async (body: string) => {
      const trimmed = body.trim();
      if (!trimmed) return;

      const localId = `pending-${Date.now()}-${Math.random().toString(36).slice(2)}`;
      setPending((p) => [...p, { localId, body: trimmed, failed: false }]);

      try {
        const result = await send.mutateAsync(trimmed);
        mergeMessages([result.message]);
        queryClient.setQueryData(SUPPORT_CONVERSATION_KEY, { conversation: result.conversation });
        setPending((p) => p.filter((m) => m.localId !== localId));
      } catch {
        setPending((p) => p.map((m) => (m.localId === localId ? { ...m, failed: true } : m)));
      }
    },
    [send, mergeMessages, queryClient],
  );

  const retry = useCallback(
    (localId: string) => {
      const message = pending.find((m) => m.localId === localId);
      if (!message) return;

      setPending((p) => p.filter((m) => m.localId !== localId));
      void sendMessage(message.body);
    },
    [pending, sendMessage],
  );

  const discard = useCallback((localId: string) => {
    setPending((p) => p.filter((m) => m.localId !== localId));
  }, []);

  return {
    conversation,
    unreadCount: conversation?.unread_count ?? 0,
    messages,
    pending,
    connection,
    hasMore,
    loadingHistory,
    loadOlder,
    sendMessage,
    retry,
    discard,
    isSending: send.isPending,
  };
}
