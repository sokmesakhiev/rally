import { useEffect, useState } from "react";
import { useMutation, useQuery, useQueryClient, keepPreviousData } from "@tanstack/react-query";
import { useTranslation } from "react-i18next";
import { Loader2, ExternalLink, ShieldAlert } from "lucide-react";
import { toast } from "sonner";

import {
  adminEventReportsApi,
  EVENT_REPORT_REASONS,
  type ApiEventReport,
  type ApiEventReportGroup,
  type EventReportPriority,
  type EventReportReason,
  type EventReportStatus,
} from "@/lib/api-client";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Textarea } from "@/components/ui/textarea";
import { ListPager } from "@/components/list-pager";
import { cn } from "@/lib/utils";

const LIST_KEY = ["admin", "event-reports"] as const;
const EVENT_KEY = ["admin", "event-reports", "event"] as const;

type StatusFilter = "live" | EventReportStatus;

/**
 * The moderation queue — the staff half of event reporting.
 *
 * Its own file rather than another section of `admin.tsx`, following
 * `AdminOverview` and `AdminSupport`. Access control is entirely server-side:
 * every `adminEventReportsApi` call needs `users.admin` and 404s otherwise.
 *
 * **A report count sets priority and nothing else.** There is no threshold at
 * which an event is hidden, greyed out or auto-suspended, and that omission is
 * the design rather than a phase two: auto-hiding on N reports hands anyone
 * with a few accounts a button that takes down a competitor's paying event, and
 * a platform that can be made to delete an organizer's work by strangers is
 * worse than one that takes an hour to review a complaint. `priority` orders a
 * human's day. A human decides.
 *
 * **Resolving is not taking the event down.** Suspension lives on the Events
 * tab (`adminApi.suspendEvent`) with its own audit entry, so the record shows a
 * reviewer chose it rather than it being implied by closing a ticket. The two
 * actions here — actioned, dismissed — say what the reviewer concluded, and
 * "actioned" is a note that they went and did something, not the doing.
 */
export function AdminEventReports() {
  const { t } = useTranslation();
  const [status, setStatus] = useState<StatusFilter>("live");
  const [reason, setReason] = useState<EventReportReason | "all">("all");
  const [page, setPage] = useState(1);
  const [selectedEventId, setSelectedEventId] = useState<string | null>(null);

  const listQuery = useQuery({
    queryKey: [...LIST_KEY, { status, reason, page }],
    queryFn: () =>
      adminEventReportsApi.list({
        // "live" is the server's default view (open + reviewing) and has no
        // status value of its own, so it's expressed by sending nothing.
        status: status === "live" ? undefined : status,
        reason: reason === "all" ? undefined : reason,
        page,
      }),
    placeholderData: keepPreviousData,
  });

  // Changing a filter has to reset the page, or filtering from page 3 of the
  // open queue lands on page 3 of a two-page result and shows an empty list
  // that looks like "nothing matches".
  const changeStatus = (value: StatusFilter) => {
    setStatus(value);
    setPage(1);
  };

  const changeReason = (value: EventReportReason | "all") => {
    setReason(value);
    setPage(1);
  };

  const groups = listQuery.data?.reports ?? [];

  // Keep the selection valid as filters change, same as the support inbox: a
  // row that dropped out of the list shouldn't leave a stale pane beside it.
  useEffect(() => {
    if (selectedEventId && !groups.some((g) => g.event.id === selectedEventId)) {
      setSelectedEventId(null);
    }
  }, [groups, selectedEventId]);

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center gap-2">
        <FilterGroup
          value={status}
          onChange={(v) => changeStatus(v as StatusFilter)}
          options={[
            ["live", t("adminReports.filterLive")],
            ["open", t("adminReports.status.open")],
            ["reviewing", t("adminReports.status.reviewing")],
            ["actioned", t("adminReports.status.actioned")],
            ["dismissed", t("adminReports.status.dismissed")],
          ]}
        />
        <FilterGroup
          value={reason}
          onChange={(v) => changeReason(v as EventReportReason | "all")}
          options={[
            ["all", t("adminReports.reasonAll")],
            ...EVENT_REPORT_REASONS.map(
              (value) => [value, t(`report.reason.${value}`)] as [string, string],
            ),
          ]}
        />

        {listQuery.data && (
          <span className="ml-auto text-sm text-muted-foreground">
            {t("adminReports.openCount", { count: listQuery.data.open_count })}
          </span>
        )}
      </div>

      <div className="grid gap-4 md:grid-cols-[22rem_1fr]">
        <div className="space-y-2">
          <ReportedEventList
            groups={groups}
            loading={listQuery.isLoading}
            selectedId={selectedEventId}
            onSelect={setSelectedEventId}
          />
          {/* Without this the queue silently ends at the first page: the
              endpoint pages at 25 and reports `total_pages`, so an event that
              fell past the cut was unreachable, not just further down. */}
          <ListPager
            meta={listQuery.data?.meta}
            onPageChange={setPage}
            busy={listQuery.isFetching}
          />
        </div>

        {selectedEventId ? (
          <ReportedEventDetail eventId={selectedEventId} />
        ) : (
          <div className="flex min-h-64 items-center justify-center rounded-lg border text-sm text-muted-foreground">
            {t("adminReports.selectPrompt")}
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
    <div className="flex flex-wrap rounded-md border p-0.5">
      {options.map(([key, label]) => (
        <button
          key={key}
          type="button"
          onClick={() => onChange(key)}
          className={cn(
            "rounded px-2.5 py-1 text-xs font-medium transition-colors",
            value === key
              ? "bg-primary text-primary-foreground"
              : "text-muted-foreground hover:text-foreground",
          )}
        >
          {label}
        </button>
      ))}
    </div>
  );
}

function PriorityBadge({ priority }: { priority: EventReportPriority }) {
  const { t } = useTranslation();
  const variant =
    priority === "urgent" ? "destructive" : priority === "high" ? "default" : "outline";

  return (
    <Badge variant={variant} className="shrink-0 text-[10px]">
      {t(`adminReports.priority.${priority}`)}
    </Badge>
  );
}

function ReportedEventList({
  groups,
  loading,
  selectedId,
  onSelect,
}: {
  groups: ApiEventReportGroup[];
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

  if (groups.length === 0) {
    return (
      <div className="flex min-h-64 items-center justify-center rounded-lg border p-4 text-center text-sm text-muted-foreground">
        {t("adminReports.emptyList")}
      </div>
    );
  }

  return (
    <ul className="max-h-[32rem] divide-y overflow-y-auto rounded-lg border">
      {groups.map((group) => (
        <li key={group.event.id}>
          <button
            type="button"
            onClick={() => onSelect(group.event.id)}
            aria-current={group.event.id === selectedId}
            className={cn(
              "flex w-full flex-col items-start gap-1 px-3 py-2.5 text-left transition-colors hover:bg-muted/60",
              group.event.id === selectedId && "bg-muted",
            )}
          >
            <span className="flex w-full items-center gap-2">
              <span className="truncate text-sm font-medium">{group.event.title}</span>
              <span className="ml-auto flex items-center gap-1.5">
                {group.event.suspended && (
                  <Badge variant="outline" className="shrink-0 text-[10px]">
                    {t("adminReports.suspended")}
                  </Badge>
                )}
                <PriorityBadge priority={group.priority} />
              </span>
            </span>
            <span className="text-xs text-muted-foreground">
              {/* Two different counts, because under a filter they answer
                  different questions: `matching` is why this row is in this
                  list, `open` is whether there's work left on the event at
                  all. Collapsing them into "3 of 5" would be wrong as soon as
                  a filter narrowed the list. */}
              {t("adminReports.openAndMatching", {
                open: group.open_count,
                matching: group.report_count,
              })}
              {" · "}
              {Object.entries(group.reasons)
                .map(([key, count]) => `${t(`report.reason.${key}`)} ×${count}`)
                .join(", ")}
            </span>
          </button>
        </li>
      ))}
    </ul>
  );
}

function ReportedEventDetail({ eventId }: { eventId: string }) {
  const { t } = useTranslation();
  const queryClient = useQueryClient();
  const [note, setNote] = useState("");

  const detailQuery = useQuery({
    queryKey: [...EVENT_KEY, eventId],
    queryFn: () => adminEventReportsApi.event(eventId),
  });

  const resolveMutation = useMutation({
    mutationFn: (status: "actioned" | "dismissed") =>
      adminEventReportsApi.resolve(eventId, status, note),
    onSuccess: (data) => {
      setNote("");
      toast.success(t("adminReports.resolved", { count: data.resolved }));
      void queryClient.invalidateQueries({ queryKey: [...EVENT_KEY, eventId] });
      void queryClient.invalidateQueries({ queryKey: [...LIST_KEY] });
    },
    onError: () => toast.error(t("adminReports.actionFailed")),
  });

  if (detailQuery.isLoading) {
    return (
      <div className="flex min-h-64 items-center justify-center rounded-lg border">
        <Loader2 className="h-5 w-5 animate-spin text-muted-foreground" />
      </div>
    );
  }

  if (!detailQuery.data) {
    return (
      <div className="flex min-h-64 items-center justify-center rounded-lg border text-sm text-muted-foreground">
        {t("adminReports.loadFailed")}
      </div>
    );
  }

  const { event, reports, total_count: totalCount } = detailQuery.data;
  const liveCount = reports.filter((r) => r.status === "open" || r.status === "reviewing").length;
  // The endpoint caps the list; say so rather than letting a truncated thread
  // read as the whole of what people said.
  const truncated = totalCount > reports.length;

  return (
    <div className="space-y-4 rounded-lg border p-4">
      <div className="space-y-1">
        <div className="flex flex-wrap items-center gap-2">
          <h3 className="text-base font-semibold">{event.title}</h3>
          {event.suspended && (
            <Badge variant="destructive" className="text-[10px]">
              {t("adminReports.suspended")}
            </Badge>
          )}
          {event.visibility === "unlisted" && (
            <Badge variant="outline" className="text-[10px]">
              {t("adminReports.unlisted")}
            </Badge>
          )}
          {/* The page itself is the evidence, so the reviewer needs one click
              to it. Opens in a new tab so the queue keeps its place. */}
          <a
            href={`/events/${event.id}`}
            target="_blank"
            rel="noreferrer"
            className="ml-auto inline-flex items-center gap-1 text-xs text-muted-foreground hover:text-foreground"
          >
            {t("adminReports.openEvent")} <ExternalLink className="h-3 w-3" />
          </a>
        </div>
        <p className="text-xs text-muted-foreground">
          {[event.organization?.name, event.category, event.location].filter(Boolean).join(" · ")}
        </p>
        {event.description && (
          <p className="max-h-32 overflow-y-auto whitespace-pre-wrap rounded-md bg-muted/50 p-2 text-xs">
            {event.description}
          </p>
        )}
      </div>

      {/* Suspension is deliberately elsewhere — see the file header. */}
      <p className="flex items-start gap-2 rounded-md border border-dashed p-2 text-xs text-muted-foreground">
        <ShieldAlert className="mt-0.5 h-3.5 w-3.5 shrink-0" aria-hidden="true" />
        {t("adminReports.suspendHint")}
      </p>

      <ul className="max-h-72 space-y-2 overflow-y-auto">
        {reports.map((report) => (
          <ReportRow key={report.id} report={report} />
        ))}
      </ul>

      {truncated && (
        <p className="text-xs text-muted-foreground">
          {t("adminReports.truncated", { shown: reports.length, total: totalCount })}
        </p>
      )}

      {liveCount > 0 ? (
        <div className="space-y-2 border-t pt-3">
          <Textarea
            value={note}
            maxLength={2000}
            onChange={(e) => setNote(e.target.value)}
            placeholder={t("adminReports.notePlaceholder")}
          />
          <div className="flex flex-wrap items-center gap-2">
            <Button
              size="sm"
              onClick={() => resolveMutation.mutate("actioned")}
              disabled={resolveMutation.isPending}
            >
              {resolveMutation.isPending && <Loader2 className="h-4 w-4 animate-spin" />}
              {t("adminReports.markActioned", { count: liveCount })}
            </Button>
            <Button
              size="sm"
              variant="outline"
              onClick={() => resolveMutation.mutate("dismissed")}
              disabled={resolveMutation.isPending}
            >
              {t("adminReports.dismiss", { count: liveCount })}
            </Button>
          </div>
        </div>
      ) : (
        <p className="border-t pt-3 text-xs text-muted-foreground">
          {t("adminReports.allResolved")}
        </p>
      )}
    </div>
  );
}

function ReportRow({ report }: { report: ApiEventReport }) {
  const { t } = useTranslation();

  return (
    <li className="rounded-md border p-2 text-sm">
      <div className="flex flex-wrap items-center gap-2">
        <Badge variant="secondary" className="text-[10px]">
          {t(`report.reason.${report.reason}`)}
        </Badge>
        <Badge variant="outline" className="text-[10px]">
          {t(`adminReports.status.${report.status}`)}
        </Badge>
        <span className="text-xs text-muted-foreground">
          {/* Anonymous is a normal case here, not missing data — the endpoint
              accepts reports without an account on purpose. */}
          {report.reporter?.email ?? t("adminReports.anonymous")}
          {" · "}
          {new Date(report.created_at).toLocaleString()}
        </span>
      </div>
      {report.details && <p className="mt-1 whitespace-pre-wrap text-xs">{report.details}</p>}
      {report.reviewed_by && (
        <p className="mt-1 text-xs text-muted-foreground">
          {t("adminReports.reviewedBy", { email: report.reviewed_by })}
          {report.reviewer_note ? ` — ${report.reviewer_note}` : ""}
        </p>
      )}
    </li>
  );
}
