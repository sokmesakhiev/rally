import { useEffect, useRef } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { openCableConsumer, type CableConsumer, type CableSubscription } from "@/lib/support-cable";

/**
 * Keeps the staff console live by invalidating its queries whenever any support
 * message is broadcast.
 *
 * ## Why this only signals, and doesn't carry data
 *
 * `SupportInboxChannel` is one shared stream for all staff, so every admin
 * receives every message regardless of which thread they have open. Trying to
 * splice those payloads into the right list row and the right open thread means
 * reimplementing the server's filtering and ordering on the client, and getting
 * it subtly wrong the first time somebody changes a sort.
 *
 * Invalidating instead costs one refetch per incoming message — cheap at this
 * volume, and it can't drift from what the API would have returned. The socket
 * buys latency here, not state.
 *
 * ## Why it isn't `useSupportChat`
 *
 * That hook owns a participant's own thread: it merges messages, tracks a
 * cursor, and holds optimistic sends. None of that applies to an inbox, and
 * sharing one hook across both would mean a pile of `if (staff)` branches for
 * two things that only superficially resemble each other.
 */
export function useSupportInbox({ enabled, queryKeys }: { enabled: boolean; queryKeys: unknown[][] }) {
  const queryClient = useQueryClient();

  // Held in a ref so a changing key array doesn't tear the socket down and
  // rebuild it — which, with single-use tickets, means a fresh ticket every
  // render.
  const keysRef = useRef(queryKeys);
  keysRef.current = queryKeys;

  useEffect(() => {
    if (!enabled) return;

    let consumer: CableConsumer | null = null;
    let subscription: CableSubscription | null = null;
    let torndown = false;
    let retry: ReturnType<typeof setTimeout> | null = null;
    let attempt = 0;

    // Bumped on every connect attempt; callbacks from a superseded attempt
    // compare against it and no-op.
    //
    // Without this, correctness rests on an ActionCable implementation detail:
    // `close()` unsubscribes *before* disconnecting, and `Subscriptions#remove`
    // synchronously filters the subscription out of the list that a later
    // `notifyAll("disconnected")` iterates — so the teardown can't trigger our
    // own `disconnected` handler and schedule a competing retry. That happens
    // to be true today. It is exactly the kind of "safe because of where this
    // happens to sit" reasoning that stops being true after a refactor, and the
    // failure mode is self-amplifying: every stray reconnect burns a single-use
    // ticket, so a loop feeds itself.
    let generation = 0;

    const close = () => {
      subscription?.unsubscribe();
      consumer?.disconnect();
      subscription = null;
      consumer = null;
    };

    const invalidateAll = () => {
      keysRef.current.forEach((key) => {
        void queryClient.invalidateQueries({ queryKey: key });
      });
    };

    const connect = async () => {
      if (torndown) return;

      const mine = ++generation;
      close();

      try {
        const next = await openCableConsumer();
        // A newer attempt started while the ticket request was in flight, or
        // the effect was cleaned up. Either way this consumer is already stale.
        if (torndown || mine !== generation) {
          next.disconnect();
          return;
        }
        consumer = next;

        subscription = next.subscriptions.create("SupportInboxChannel", {
          connected() {
            if (mine !== generation) return;
            attempt = 0;
            // Catch up on anything that landed while disconnected.
            invalidateAll();
          },
          disconnected() {
            if (mine !== generation) return;
            scheduleRetry();
          },
          rejected() {
            if (mine !== generation) return;
            // Not an admin (any more). Retrying can't fix that.
            torndown = true;
            close();
          },
          received() {
            if (mine !== generation) return;
            invalidateAll();
          },
        });
      } catch {
        if (mine !== generation) return;
        scheduleRetry();
      }
    };

    // Own backoff rather than ActionCable's: its monitor would replay the same
    // URL, and the ticket in that URL is single-use. See support-cable.ts.
    const scheduleRetry = () => {
      if (torndown) return;

      // Clear first: two retries stacking would mean two concurrent connects,
      // each burning its own single-use ticket, and the loser's teardown racing
      // the winner's setup.
      if (retry) clearTimeout(retry);

      const delay = Math.min(1_000 * 2 ** attempt, 15_000);
      attempt += 1;
      retry = setTimeout(() => void connect(), delay);
    };

    void connect();

    return () => {
      torndown = true;
      if (retry) clearTimeout(retry);
      close();
    };
  }, [enabled, queryClient]);
}
