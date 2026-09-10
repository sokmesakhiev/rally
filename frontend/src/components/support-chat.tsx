import { useEffect, useRef, useState } from "react";
import { useTranslation } from "react-i18next";
import { MessageCircle, X, RotateCcw, Send } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Textarea } from "@/components/ui/textarea";
import { useAuth } from "@/lib/use-auth";
import { useSupportChat, type ConnectionState } from "@/lib/use-support-chat";
import { cn } from "@/lib/utils";

/**
 * The support chat launcher and panel.
 *
 * Rendered once, from `__root.tsx`, so it's reachable from every page — a
 * participant who needs help is usually stuck on the page where they got stuck,
 * not willing to navigate to a support section first.
 *
 * **Signed-in users only.** An anonymous visitor gets nothing: no bubble, no
 * poll, no socket, and no `@rails/actioncable` in their bundle. Support chat
 * needs an account to attach the conversation to, and offering it to someone
 * who'd then have to sign up mid-question would be worse than not offering it.
 */
export function SupportChat() {
  const { user } = useAuth();
  const [open, setOpen] = useState(false);

  // Hooks can't be called conditionally, so the gate is inside: with no user
  // the hook disables its query and never opens a socket.
  const chat = useSupportChat({ open });
  const { t } = useTranslation();

  if (!user) return null;

  return (
    <>
      {open && <SupportChatPanel chat={chat} onClose={() => setOpen(false)} />}

      <Button
        type="button"
        size="icon"
        onClick={() => setOpen((v) => !v)}
        aria-expanded={open}
        aria-label={
          chat.unreadCount > 0
            ? t("supportChat.launcherWithCount", { count: chat.unreadCount })
            : t("supportChat.launcher")
        }
        className="fixed bottom-4 right-4 z-50 h-12 w-12 rounded-full shadow-lg"
      >
        {open ? <X className="h-5 w-5" /> : <MessageCircle className="h-5 w-5" />}
        {!open && chat.unreadCount > 0 && (
          <span
            className="absolute -right-0.5 -top-0.5 flex h-5 min-w-5 items-center justify-center rounded-full bg-destructive px-1 text-[10px] font-semibold leading-none text-white"
            // The count is already in the button's aria-label; announcing it
            // twice makes the control read as "support, 2 unread 2".
            aria-hidden="true"
          >
            {chat.unreadCount}
          </span>
        )}
      </Button>
    </>
  );
}

function SupportChatPanel({
  chat,
  onClose,
}: {
  chat: ReturnType<typeof useSupportChat>;
  onClose: () => void;
}) {
  const { t } = useTranslation();
  const [draft, setDraft] = useState("");
  const scrollRef = useRef<HTMLDivElement>(null);

  // Stick to the newest message as the thread grows.
  //
  // `scrollTop = scrollHeight` rather than `scrollTo({...})`: the latter isn't
  // implemented on elements in jsdom, so it throws inside this effect under
  // test — and an effect that throws takes the whole panel down, which is a
  // real fragility rather than a testing inconvenience. Instant is also the
  // right behaviour here; nobody wants to watch a chat animate to the bottom.
  useEffect(() => {
    const list = scrollRef.current;
    if (list) list.scrollTop = list.scrollHeight;
  }, [chat.messages.length, chat.pending.length]);

  const submit = () => {
    const body = draft.trim();
    if (!body) return;
    setDraft("");
    void chat.sendMessage(body);
  };

  const isEmpty = chat.messages.length === 0 && chat.pending.length === 0;

  return (
    <div
      role="dialog"
      aria-label={t("supportChat.title")}
      className="fixed bottom-20 right-4 z-50 flex h-[28rem] w-[min(22rem,calc(100vw-2rem))] flex-col overflow-hidden rounded-lg border bg-background shadow-xl"
    >
      <header className="flex items-center justify-between border-b px-4 py-3">
        <div>
          <p className="text-sm font-semibold">{t("supportChat.title")}</p>
          <ConnectionLine state={chat.connection} />
        </div>
        <Button type="button" variant="ghost" size="icon" onClick={onClose} aria-label={t("common.close")}>
          <X className="h-4 w-4" />
        </Button>
      </header>

      <div ref={scrollRef} className="flex-1 space-y-2 overflow-y-auto px-4 py-3">
        {chat.hasMore && (
          <div className="text-center">
            <button
              type="button"
              onClick={() => void chat.loadOlder()}
              disabled={chat.loadingHistory}
              className="text-xs text-muted-foreground underline-offset-2 hover:underline"
            >
              {chat.loadingHistory ? t("supportChat.loading") : t("supportChat.loadOlder")}
            </button>
          </div>
        )}

        {isEmpty && (
          <div className="py-8 text-center">
            <p className="text-sm text-muted-foreground">{t("supportChat.emptyTitle")}</p>
            <p className="mt-1 text-xs text-muted-foreground">{t("supportChat.emptyHint")}</p>
          </div>
        )}

        {chat.messages.map((message) =>
          message.sender_role === "system" ? (
            <p key={message.id} className="py-1 text-center text-xs text-muted-foreground">
              {message.body}
            </p>
          ) : (
            <Bubble key={message.id} mine={message.sender_role === "participant"} body={message.body} />
          ),
        )}

        {chat.pending.map((message) => (
          <div key={message.localId} className="flex flex-col items-end">
            <Bubble mine body={message.body} muted={!message.failed} />
            {message.failed && (
              <div className="mt-1 flex items-center gap-2 text-xs text-destructive">
                <span>{t("supportChat.sendFailed")}</span>
                <button
                  type="button"
                  onClick={() => chat.retry(message.localId)}
                  className="inline-flex items-center gap-1 underline-offset-2 hover:underline"
                >
                  <RotateCcw className="h-3 w-3" />
                  {t("supportChat.retry")}
                </button>
                <button
                  type="button"
                  onClick={() => chat.discard(message.localId)}
                  className="underline-offset-2 hover:underline"
                >
                  {t("supportChat.discard")}
                </button>
              </div>
            )}
          </div>
        ))}
      </div>

      <form
        className="flex items-end gap-2 border-t px-3 py-2"
        onSubmit={(event) => {
          event.preventDefault();
          submit();
        }}
      >
        <Textarea
          value={draft}
          onChange={(event) => setDraft(event.target.value)}
          placeholder={t("supportChat.placeholder")}
          aria-label={t("supportChat.placeholder")}
          rows={1}
          className="max-h-24 min-h-9 resize-none"
          onKeyDown={(event) => {
            // Enter sends, Shift+Enter breaks the line — the convention every
            // chat client uses, and the one people's fingers already know.
            if (event.key === "Enter" && !event.shiftKey) {
              event.preventDefault();
              submit();
            }
          }}
        />
        <Button type="submit" size="icon" disabled={!draft.trim()} aria-label={t("supportChat.send")}>
          <Send className="h-4 w-4" />
        </Button>
      </form>
    </div>
  );
}

/**
 * Connection state has to be visible. A composer that silently swallows
 * messages while the socket is down is worse than one that says so — and
 * "connected" needs no announcement, so it renders nothing.
 */
function ConnectionLine({ state }: { state: ConnectionState }) {
  const { t } = useTranslation();

  if (state === "connected" || state === "idle") return null;

  return (
    <p className={cn("text-xs", state === "failed" ? "text-destructive" : "text-muted-foreground")}>
      {state === "failed" ? t("supportChat.disconnected") : t("supportChat.connecting")}
    </p>
  );
}

function Bubble({ mine, body, muted }: { mine: boolean; body: string; muted?: boolean }) {
  return (
    <div className={cn("flex", mine ? "justify-end" : "justify-start")}>
      <p
        className={cn(
          "max-w-[85%] whitespace-pre-wrap rounded-lg px-3 py-2 text-sm",
          mine ? "bg-primary text-primary-foreground" : "bg-muted text-foreground",
          muted && "opacity-60",
        )}
      >
        {body}
      </p>
    </div>
  );
}
