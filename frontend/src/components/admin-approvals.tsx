/**
 * The four-eyes queue — where a second staff member signs off the actions
 * that one person shouldn't take alone. See docs/staff-roles-design.md D9.
 *
 * Two things about approving here are worth knowing, because they're not
 * symmetrical:
 *
 *   - A `grant_staff_role` request is *applied* the moment it's approved
 *     (D11), so the button below really does change somebody's access.
 *   - Every other action is only *unlocked*. The requester goes back to its
 *     own endpoint and performs it there, which is what keeps one
 *     implementation of each irreversible action rather than two.
 *
 * Access control is entirely server-side. Every row's Approve refuses unless
 * the signer holds the capability that row asks for and is not the person who
 * raised it — so a support agent seeing a queue full of things they can't sign
 * is expected, not a bug.
 */
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { CheckCircle2, Clock, Loader2, XCircle } from "lucide-react";
import { toast } from "sonner";
import { useTranslation } from "react-i18next";

import { staffApprovalsApi, type ApiStaffApproval } from "@/lib/api-client";
import { useAuth } from "@/lib/use-auth";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { formatDateTime } from "@/lib/event-utils";

const KEY = ["admin", "staff-approvals"] as const;

export function AdminApprovals() {
  const { t } = useTranslation();
  const { user } = useAuth();
  const queryClient = useQueryClient();

  const query = useQuery({
    queryKey: KEY,
    queryFn: () => staffApprovalsApi.list(),
  });

  const invalidate = () => queryClient.invalidateQueries({ queryKey: KEY });

  const approve = useMutation({
    mutationFn: (id: string) => staffApprovalsApi.approve(id),
    onSuccess: () => {
      toast.success(t("approvals.toastApproved"));
      invalidate();
    },
    onError: (e: Error) => toast.error(e.message),
  });

  const reject = useMutation({
    mutationFn: (id: string) => staffApprovalsApi.reject(id),
    onSuccess: () => {
      toast.success(t("approvals.toastRejected"));
      invalidate();
    },
    onError: (e: Error) => toast.error(e.message),
  });

  if (query.isLoading) {
    return <p className="text-sm text-muted-foreground">{t("common.loading")}</p>;
  }

  const approvals = query.data?.staff_approvals ?? [];
  const pending = approvals.filter((a) => a.status === "pending" && !a.expired);

  return (
    <div className="space-y-6">
      <div>
        <h2 className="font-semibold">{t("approvals.title")}</h2>
        <p className="mt-1 text-sm text-muted-foreground">{t("approvals.subtitle")}</p>
        <p className="mt-2 text-sm font-medium">
          {t("approvals.pendingCount", { count: pending.length })}
        </p>
      </div>

      {approvals.length === 0 ? (
        <p className="rounded-2xl border border-border p-8 text-center text-sm text-muted-foreground">
          {t("approvals.empty")}
        </p>
      ) : (
        <div className="overflow-hidden rounded-2xl border border-border divide-y divide-border">
          {approvals.map((approval) => (
            <ApprovalRow
              key={approval.id}
              approval={approval}
              // Surfaced as a disabled button with a reason rather than a
              // hidden one: "why can't I approve this?" is a question the UI
              // should answer, and the commonest answer is "because you
              // asked for it".
              isOwnRequest={approval.requester.id === user?.id}
              busy={approve.isPending || reject.isPending}
              onApprove={() => approve.mutate(approval.id)}
              onReject={() => reject.mutate(approval.id)}
            />
          ))}
        </div>
      )}
    </div>
  );
}

function ApprovalRow({
  approval,
  isOwnRequest,
  busy,
  onApprove,
  onReject,
}: {
  approval: ApiStaffApproval;
  isOwnRequest: boolean;
  busy: boolean;
  onApprove: () => void;
  onReject: () => void;
}) {
  const { t } = useTranslation();
  const open = approval.status === "pending" && !approval.expired;

  return (
    <div className="flex flex-wrap items-start justify-between gap-4 p-4">
      <div className="min-w-0 space-y-1">
        <div className="flex flex-wrap items-center gap-2">
          <p className="font-medium">{t(`approvals.action.${approval.action}`)}</p>
          <StatusBadge approval={approval} />
        </div>

        {/* The payload is what was actually authorised — a refund of *this*
            amount, a grant of *this* role. Showing it is the difference
            between approving a thing and approving a category of thing. */}
        {Object.keys(approval.payload).length > 0 && (
          <p className="font-mono text-xs text-muted-foreground">
            {Object.entries(approval.payload)
              .map(([k, v]) => `${k}: ${String(v)}`)
              .join(" · ")}
          </p>
        )}

        <p className="text-sm text-muted-foreground">{approval.reason}</p>
        <p className="text-xs text-muted-foreground">
          {t("approvals.requestedBy", {
            email: approval.requester.email,
            at: formatDateTime(approval.created_at),
          })}
        </p>
      </div>

      {open && (
        <div className="flex flex-wrap items-center gap-2">
          {isOwnRequest ? (
            <span className="text-xs text-muted-foreground">{t("approvals.yourOwnRequest")}</span>
          ) : (
            <>
              <Button size="sm" variant="outline" disabled={busy} onClick={onReject}>
                <XCircle className="h-3.5 w-3.5" /> {t("approvals.reject")}
              </Button>
              <Button size="sm" disabled={busy} onClick={onApprove} className="gap-1">
                {busy && <Loader2 className="h-3.5 w-3.5 animate-spin" />}
                <CheckCircle2 className="h-3.5 w-3.5" /> {t("approvals.approve")}
              </Button>
            </>
          )}
        </div>
      )}
    </div>
  );
}

function StatusBadge({ approval }: { approval: ApiStaffApproval }) {
  const { t } = useTranslation();

  // `expired` beats the stored status: the server evaluates it rather than
  // storing it, so a row can read "pending" and be long past acting on.
  if (approval.expired && approval.status === "pending") {
    return (
      <Badge variant="outline" className="gap-1">
        <Clock className="h-3 w-3" /> {t("approvals.status.expired")}
      </Badge>
    );
  }

  const variant =
    approval.status === "rejected"
      ? "destructive"
      : approval.status === "pending"
        ? "default"
        : "secondary";

  return <Badge variant={variant}>{t(`approvals.status.${approval.status}`)}</Badge>;
}
