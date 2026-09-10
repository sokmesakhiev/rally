import { useEffect, useState } from "react";
import { useMutation, useQuery, useQueryClient, keepPreviousData } from "@tanstack/react-query";
import { useTranslation } from "react-i18next";
import { Loader2, Send, UserCheck, UserMinus, CheckCircle2 } from "lucide-react";
import { toast } from "sonner";

import {
  adminSupportApi,
  type ApiAdminConversation,
  type ApiAdminSupportMessage,
  type ApiSupportParticipant,
} from "@/lib/api-client";
import { useAuth } from "@/lib/use-auth";
import { useSupportInbox } from "@/lib/use-support-inbox";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Textarea } from "@/components/ui/textarea";
import { cn } from "@/lib/utils";

const LIST_KEY = ["admin", "support", "conversations"] as const;
const THREAD_KEY = ["admin", "support", "conversation"] as const;

type StatusFilter = "live" | "open" | "pending" | "resolved" | "all";
type AssignmentFilter = "any" | "mine" | "unassigned";

/**
 * The staff side of support chat — a fourth tab in the admin console.
 *
 * Extracted to its own file rather than added to `admin.tsx`, which is already
 * ~700 lines of moderation tables; `AdminOverview` set that precedent.
 *
 * Access control is entirely server-side: every `adminSupportApi` call requires
 * `users.admin` and 404s otherwise. Nothing here is what keeps a non-admin out.
 */
export function AdminSupport() {
  const { t } = useTranslation();
  const { user } = useAuth();
  const [status, setStatus] = useState<StatusFilter>("live");
  const [assignment, setAssignment] = useState<AssignmentFilter>("any");
  const [unreadOnly, setUnreadOnly] = useState(false);
  const [selectedId, setSelectedId] = useState<string | null>(null);

  const listQuery = useQuery({
    queryKey: [...LIST_KEY, { status, assignment, unreadOnly }],
    queryFn: () =>
      adminSupportApi.conversations({
        status,
        assignment,
        unread: unreadOnly || undefined,
      }),
    placeholderData: keepPreviousData,
  });

  // One subscription for the whole tab. It only signals; the queries refetch.
  useSupportInbox({
    enabled: Boolean(user?.admin),
    queryKeys: [[...LIST_KEY], [...THREAD_KEY]],
  });

  const conversations = listQuery.data?.conversations ?? [];

  // Keep a selection valid as filters change — a thread that dropped out of the
  // list shouldn't leave a stale pane open beside it.
  useEffect(() => {
    if (selectedId && !conversations.some((c) => c.id === selectedId)) setSelectedId(null);
  }, [conversations, selectedId]);

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center gap-2">
        <FilterGroup
          value={status}
          onChange={(v) => setStatus(v as StatusFilter)}
          options={[
            ["live", t("adminSupport.filterLive")],
            ["open", t("adminSupport.filterOpen")],
            ["pending", t("adminSupport.filterPending")],
            ["resolved", t("adminSupport.filterResolved")],
            ["all", t("adminSupport.filterAll")],
          ]}
        />
        <FilterGroup
          value={assignment}
          onChange={(v) => setAssignment(v as AssignmentFilter)}
          options={[
            ["any", t("adminSupport.assignmentAny")],
            ["mine", t("adminSupport.assignmentMine")],
            ["unassigned", t("adminSupport.assignmentUnassigned")],
          ]}
        />
        <Button
          type="button"
          size="sm"
          variant={unreadOnly ? "default" : "outline"}
          onClick={() => setUnreadOnly((v) => !v)}
        >
          {t("adminSupport.filterUnread")}
        </Button>

        {listQuery.data && (
          <span className="ml-auto text-sm text-muted-foreground">
            {t("adminSupport.awaitingCount", { count: listQuery.data.awaiting_count })}
          </span>
        )}
      </div>

      <div className="grid gap-4 md:grid-cols-[20rem_1fr]">
        <ConversationList
          conversations={conversations}
          loading={listQuery.isLoading}
          selectedId={selectedId}
          onSelect={setSelectedId}
        />

        {selectedId ? (
          <ConversationThread id={selectedId} />
        ) : (
          <div className="flex min-h-64 items-center justify-center rounded-lg border text-sm text-muted-foreground">
            {t("adminSupport.selectPrompt")}
          </div>
        )}
      </div>
    </div>
  );
}

function FilterGroup({
  value,
  onChange,
  options,
}: {
  value: string;
  onChange: (value: string) => void;
  options: Array<[string, string]>;
}) {
  return (
    <div className="flex rounded-md border p-0.5">
      {options.map(([key, label]) => (
        <button
          key={key}
          type="button"
          onClick={() => onChange(key)}
          className={cn(
            "rounded px-2.5 py-1 text-xs font-medium transition-colors",
            value === key ? "bg-primary text-primary-foreground" : "text-muted-foreground hover:text-foreground",
          )}
        >
          {label}
        </button>
      ))}
    </div>
  );
}

function ConversationList({
  conversations,
  loading,
  selectedId,
  onSelect,
}: {
  conversations: ApiAdminConversation[];
  loading: boolean;
  selectedId: string | null;
  onSelect: (id: string) => void;
}) {
  const { t } = useTranslation();

  if (loading) {
    return (
      <div className="flex min-h-64 items-center justify-center rounded-lg border">
        <Loader2 className="h-5 w-5 animate-spin text-muted-foreground" />
      </div>
    );
  }

  if (conversations.length === 0) {
    return (
      <div className="flex min-h-64 items-center justify-center rounded-lg border p-4 text-center text-sm text-muted-foreground">
        {t("adminSupport.emptyList")}
      </div>
    );
  }

  return (
    <ul className="max-h-[32rem] divide-y overflow-y-auto rounded-lg border">
      {conversations.map((conversation) => (
        <li key={conversation.id}>
          <button
            type="button"
            onClick={() => onSelect(conversation.id)}
            aria-current={conversation.id === selectedId}
            className={cn(
              "flex w-full flex-col items-start gap-1 px-3 py-2.5 text-left transition-colors hover:bg-muted/60",
              conversation.id === selectedId && "bg-muted",
            )}
          >
            <span className="flex w-full items-center gap-2">
              {conversation.unread && (
                <span className="h-1.5 w-1.5 shrink-0 rounded-full bg-primary" aria-hidden="true" />
              )}
              <span className="truncate text-sm font-medium">
                {conversation.participant.display_name || conversation.participant.email}
              </span>
              <StatusBadge status={conversation.status} />
            </span>
            {conversation.subject && (
              <span className="truncate text-xs text-muted-foreground">{conversation.subject}</span>
            )}
          </button>
        </li>
      ))}
    </ul>
  );
}

function StatusBadge({ status }: { status: ApiAdminConversation["status"] }) {
  const { t } = useTranslation();
  const variant = status === "open" ? "default" : status === "pending" ? "secondary" : "outline";

  return (
    <Badge variant={variant} className="ml-auto shrink-0 text-[10px]">
      {t(`adminSupport.status.${status}`)}
    </Badge>
  );
}

function ConversationThread({ id }: { id: string }) {
  const { t } = useTranslation();
  const { user } = useAuth();
  const queryClient = useQueryClient();
  const [draft, setDraft] = useState("");

  const threadQuery = useQuery({
    queryKey: [...THREAD_KEY, id],
    queryFn: () => adminSupportApi.conversation(id),
  });

  const invalidate = () => {
    void queryClient.invalidateQueries({ queryKey: [...THREAD_KEY, id] });
    void queryClient.invalidateQueries({ queryKey: [...LIST_KEY] });
  };

  // Opening a thread is reading it. Fires once per thread rather than on every
  // refetch, so a live-updating pane doesn't spam the endpoint.
  useEffect(() => {
    adminSupportApi
      .markRead(id)
      .then(() => queryClient.invalidateQueries({ queryKey: [...LIST_KEY] }))
      // Swallowed deliberately: failing to mark a thread read leaves it bold in
      // the list, which is a cosmetic annoyance the next open will fix. Without
      // the catch it becomes an unhandled rejection instead — noise that
      // obscures failures that do matter.
      .catch(() => {});
  }, [id, queryClient]);

  const reply = useMutation({
    mutationFn: (body: string) => adminSupportApi.reply(id, body),
    onSuccess: () => {
      setDraft("");
      invalidate();
    },
    onError: () => toast.error(t("adminSupport.replyFailed")),
  });

  const act = useMutation({
    mutationFn: (action: "assign" | "unassign" | "resolve") => adminSupportApi[action](id),
    onSuccess: invalidate,
    // assign is refused on a resolved thread — surface the server's reason
    // rather than a generic failure.
    onError: (error: unknown) =>
      toast.error((error as { message?: string })?.message || t("adminSupport.actionFailed")),
  });

  if (threadQuery.isLoading || !threadQuery.data) {
    return (
      <div className="flex min-h-64 items-center justify-center rounded-lg border">
        <Loader2 className="h-5 w-5 animate-spin text-muted-foreground" />
      </div>
    );
  }

  const { conversation, participant, messages } = threadQuery.data;
  const mine = conversation.assigned_admin_id === user?.id;

  return (
    <div className="grid gap-4 lg:grid-cols-[1fr_16rem]">
      <div className="flex flex-col rounded-lg border">
        <header className="flex flex-wrap items-center gap-2 border-b px-4 py-3">
          <div className="mr-auto">
            <p className="text-sm font-semibold">
              {participant.display_name || participant.email}
            </p>
            <p className="text-xs text-muted-foreground">{participant.email}</p>
          </div>

          <Button
            type="button"
            size="sm"
            variant="outline"
            disabled={act.isPending}
            onClick={() => act.mutate(mine ? "unassign" : "assign")}
          >
            {mine ? <UserMinus className="mr-1.5 h-3.5 w-3.5" /> : <UserCheck className="mr-1.5 h-3.5 w-3.5" />}
            {mine ? t("adminSupport.release") : t("adminSupport.claim")}
          </Button>

          {conversation.status !== "resolved" && (
            <Button
              type="button"
              size="sm"
              variant="outline"
              disabled={act.isPending}
              onClick={() => act.mutate("resolve")}
            >
              <CheckCircle2 className="mr-1.5 h-3.5 w-3.5" />
              {t("adminSupport.resolve")}
            </Button>
          )}
        </header>

        <div className="max-h-96 flex-1 space-y-2 overflow-y-auto px-4 py-3">
          {messages.map((message) => (
            <MessageRow key={message.id} message={message} />
          ))}
        </div>

        <form
          className="flex items-end gap-2 border-t px-3 py-2"
          onSubmit={(event) => {
            event.preventDefault();
            const body = draft.trim();
            if (body) reply.mutate(body);
          }}
        >
          <Textarea
            value={draft}
            onChange={(event) => setDraft(event.target.value)}
            rows={2}
            placeholder={t("adminSupport.replyPlaceholder")}
            aria-label={t("adminSupport.replyPlaceholder")}
            className="max-h-32 resize-none"
          />
          <Button type="submit" size="icon" disabled={!draft.trim() || reply.isPending} aria-label={t("adminSupport.send")}>
            <Send className="h-4 w-4" />
          </Button>
        </form>
      </div>

      <ParticipantContext participant={participant} />
    </div>
  );
}

function MessageRow({ message }: { message: ApiAdminSupportMessage }) {
  const { t } = useTranslation();

  if (message.sender_role === "system") {
    return <p className="py-1 text-center text-xs text-muted-foreground">{message.body}</p>;
  }

  const fromStaff = message.sender_role === "staff";

  return (
    <div className={cn("flex flex-col", fromStaff ? "items-end" : "items-start")}>
      <span className="px-1 text-[10px] text-muted-foreground">
        {fromStaff ? message.sender_name || t("adminSupport.deletedAccount") : t("adminSupport.participant")}
      </span>
      <p
        className={cn(
          "max-w-[85%] whitespace-pre-wrap rounded-lg px-3 py-2 text-sm",
          fromStaff ? "bg-primary text-primary-foreground" : "bg-muted text-foreground",
        )}
      >
        {message.body}
      </p>
    </div>
  );
}

/**
 * The whole argument for building this rather than embedding a hosted widget:
 * an agent sees what this person actually registered for and whether they paid,
 * without leaving the page to look them up.
 */
function ParticipantContext({ participant }: { participant: ApiSupportParticipant }) {
  const { t } = useTranslation();

  return (
    <aside className="space-y-3 rounded-lg border p-3">
      <div>
        <p className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">
          {t("adminSupport.contextTitle")}
        </p>
        {participant.suspended && (
          <Badge variant="destructive" className="mt-1 text-[10px]">
            {t("adminSupport.suspended")}
          </Badge>
        )}
      </div>

      {participant.registrations.length === 0 ? (
        <p className="text-xs text-muted-foreground">{t("adminSupport.noRegistrations")}</p>
      ) : (
        <ul className="space-y-2">
          {participant.registrations.map((registration) => (
            <li key={registration.id} className="rounded border px-2 py-1.5">
              <p className="truncate text-xs font-medium">
                {registration.event_title || t("adminSupport.untitledEvent")}
              </p>
              <p className="text-[11px] text-muted-foreground">
                {t(`adminSupport.paymentStatus.${registration.payment_status}`, {
                  defaultValue: registration.payment_status,
                })}
                {registration.amount_paid_cents > 0 &&
                  ` · $${(registration.amount_paid_cents / 100).toFixed(2)}`}
                {registration.refunded_cents > 0 &&
                  ` · ${t("adminSupport.refunded", {
                    amount: `$${(registration.refunded_cents / 100).toFixed(2)}`,
                  })}`}
              </p>
            </li>
          ))}
        </ul>
      )}
    </aside>
  );
}
