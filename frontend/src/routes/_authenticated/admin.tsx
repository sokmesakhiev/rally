/**
 * Minimal Rally staff moderation console.
 *
 * Deliberately plain: two tables with action buttons, no charts or bulk
 * operations. This exists to close the trust & safety gap (no way to suspend an
 * abusive account or take down bad content) rather than to be a full admin
 * product.
 *
 * Access control is server-side. Every adminApi call requires an admin account
 * and returns 404 otherwise, so a non-admin who navigates here directly just
 * sees the error state — the `user.admin` check below only decides whether to
 * bother rendering the UI, it is not the thing keeping anyone out.
 */
import { useState, type ReactNode } from "react";
import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useQuery, useMutation, useQueryClient, keepPreviousData } from "@tanstack/react-query";
import {
  ShieldAlert,
  Search,
  Loader2,
  Ban,
  RotateCcw,
  EyeOff,
  Trash2,
  ChevronLeft,
  ChevronRight,
  LayoutDashboard,
  BadgeCheck,
  ShieldOff,
  Eye,
  MoreHorizontal,
} from "lucide-react";
import { toast } from "sonner";
import { useTranslation } from "react-i18next";

import {
  adminApi,
  staffApprovalsApi,
  type ApiAdminUser,
  type ApiAdminEvent,
  type StaffRole,
} from "@/lib/api-client";
import { useAuth } from "@/lib/use-auth";
import { SiteHeader } from "@/components/site-header";
import { AdminOverview } from "@/components/admin-overview";
import { AdminSupport } from "@/components/admin-support";
import { AdminEventReports } from "@/components/admin-event-reports";
import { AdminApprovals } from "@/components/admin-approvals";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { Tabs, TabsList, TabsTrigger, TabsContent } from "@/components/ui/tabs";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
  AlertDialogTrigger,
} from "@/components/ui/alert-dialog";
import {
  Sheet,
  SheetContent,
  SheetDescription,
  SheetHeader,
  SheetTitle,
} from "@/components/ui/sheet";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { formatDate, formatDateTime, formatPrice, categoryLabel } from "@/lib/event-utils";

const PER_PAGE = 25;

const ADMIN_TABS = ["overview", "users", "events", "reports", "support", "approvals"] as const;
type AdminTab = (typeof ADMIN_TABS)[number];

/**
 * Which tabs each staff role sees — the client-side shadow of
 * `StaffAuthorization::CAPABILITIES`. See docs/staff-roles-design.md D4.
 *
 * **This hides buttons; it does not grant anything.** Every endpoint behind
 * every tab re-checks `require_staff!(capability)` server-side, and that is
 * the only thing standing between a role and an action. Rendering a tab
 * somebody can't use is a cosmetic bug; *not* rendering one they can is too.
 * Neither is a security incident, which is exactly why this table is allowed
 * to be a simplification of the server's matrix rather than a copy of it.
 *
 * Support gets Support and Users — a chat agent needs to look up the person
 * they're talking to. Moderator adds the report queue, events, and the
 * analytics on Overview. Admin sees everything.
 */
const TABS_BY_ROLE: Record<StaffRole, readonly AdminTab[]> = {
  support: ["support", "users", "approvals"],
  moderator: ["overview", "users", "events", "reports", "support", "approvals"],
  admin: ADMIN_TABS,
};

export const Route = createFileRoute("/_authenticated/admin")({
  head: () => ({ meta: [{ title: "Admin — Rally" }] }),
  /**
   * `?tab=` exists so a notification can deep-link into the console —
   * `Notifications::ModerationNotifier` sends `/admin?tab=reports`, and a
   * moderation alert that drops a reviewer on the Overview tab makes them go
   * and find the thing they were alerted about.
   *
   * Unknown values fall through to the default rather than erroring: a stale
   * link in an old notification should open the console, not break it.
   */
  validateSearch: (search: Record<string, unknown>): { tab?: AdminTab } => {
    const tab = search.tab;
    return typeof tab === "string" && (ADMIN_TABS as readonly string[]).includes(tab)
      ? { tab: tab as AdminTab }
      : {};
  },
  component: AdminConsole,
});

function AdminConsole() {
  const { t } = useTranslation();
  const { user } = useAuth();
  const navigate = Route.useNavigate();
  const { tab } = Route.useSearch();

  // `staff_role` when the backend sends it, falling back to the boolean so a
  // client loaded before the backend deploy — or after Phase 3 removes the
  // column — still resolves to something sensible.
  const role: StaffRole | null = user?.staff_role ?? (user?.admin ? "admin" : null);
  const visibleTabs = role ? TABS_BY_ROLE[role] : [];

  if (user && visibleTabs.length === 0) {
    return (
      <div className="min-h-screen bg-background">
        <SiteHeader />
        <main className="mx-auto max-w-2xl px-5 py-20 text-center">
          <h1 className="font-display text-2xl font-bold">{t("admin.notAuthorizedTitle")}</h1>
          <p className="mt-2 text-muted-foreground">{t("admin.notAuthorizedDesc")}</p>
        </main>
      </div>
    );
  }

  // A support agent deep-linked to ?tab=reports, or landing on the default
  // "overview" they can't see, gets their own first tab instead of an empty
  // panel. Same spirit as validateSearch accepting a stale tab rather than
  // erroring: the console should open, not break.
  const activeTab: AdminTab =
    tab && visibleTabs.includes(tab) ? tab : (visibleTabs[0] ?? "overview");

  return (
    <div className="min-h-screen bg-background">
      <SiteHeader />
      <main className="mx-auto max-w-6xl px-5 py-10">
        <div className="flex items-center gap-2">
          <ShieldAlert className="h-6 w-6 text-muted-foreground" />
          <h1 className="font-display text-2xl font-bold">{t("admin.title")}</h1>
        </div>
        <p className="mt-2 text-sm text-muted-foreground">{t("admin.subtitle")}</p>

        {/* Controlled rather than `defaultValue`, so the URL is the source of
            truth and a deep-linked notification opens the right tab. */}
        <Tabs
          value={activeTab}
          onValueChange={(value) => navigate({ search: { tab: value as AdminTab }, replace: true })}
          className="mt-8"
        >
          <TabsList>
            {visibleTabs.includes("overview") && (
              <TabsTrigger value="overview">
                <LayoutDashboard className="h-4 w-4 mr-1.5" /> {t("admin.tabOverview")}
              </TabsTrigger>
            )}
            {visibleTabs.includes("users") && (
              <TabsTrigger value="users">{t("admin.tabUsers")}</TabsTrigger>
            )}
            {visibleTabs.includes("events") && (
              <TabsTrigger value="events">{t("admin.tabEvents")}</TabsTrigger>
            )}
            {visibleTabs.includes("reports") && (
              <TabsTrigger value="reports">{t("admin.tabReports")}</TabsTrigger>
            )}
            {visibleTabs.includes("support") && (
              <TabsTrigger value="support">{t("admin.tabSupport")}</TabsTrigger>
            )}
            {visibleTabs.includes("approvals") && (
              <TabsTrigger value="approvals">{t("admin.tabApprovals")}</TabsTrigger>
            )}
          </TabsList>

          <TabsContent value="overview" className="mt-6">
            <AdminOverview />
          </TabsContent>
          <TabsContent value="users" className="mt-6">
            <UsersPanel />
          </TabsContent>
          <TabsContent value="events" className="mt-6">
            <EventsPanel />
          </TabsContent>
          {/* Extracted like AdminOverview rather than inlined — this file is
              already ~700 lines of moderation tables. */}
          <TabsContent value="reports" className="mt-6">
            <AdminEventReports />
          </TabsContent>
          <TabsContent value="approvals" className="mt-6">
            <AdminApprovals />
          </TabsContent>

          <TabsContent value="support" className="mt-6">
            <AdminSupport />
          </TabsContent>
        </Tabs>
      </main>
    </div>
  );
}

// ─── Users ────────────────────────────────────────────────────────────────────

function UsersPanel() {
  const { t } = useTranslation();
  const queryClient = useQueryClient();

  const [q, setQ] = useState("");
  const [status, setStatus] = useState<"all" | "active" | "suspended">("all");
  const [page, setPage] = useState(1);
  // The row the detail sheet is open for. An id rather than the row object, so
  // the sheet re-reads from the server rather than rendering a snapshot that a
  // suspension or role change taken from inside it would leave stale.
  const [detailId, setDetailId] = useState<string | null>(null);

  const query = useQuery({
    queryKey: ["admin-users", q, status, page],
    queryFn: () => adminApi.users({ q, status, page, perPage: PER_PAGE }),
    placeholderData: keepPreviousData,
  });

  const invalidate = () => {
    queryClient.invalidateQueries({ queryKey: ["admin-users"] });
    // A suspension unpublishes the user's events, so the events tab is stale too.
    queryClient.invalidateQueries({ queryKey: ["admin-events"] });
  };

  const unsuspend = useMutation({
    mutationFn: (id: string) => adminApi.unsuspendUser(id),
    onSuccess: () => {
      invalidate();
      toast.success(t("admin.toastUnsuspended"));
    },
    onError: (e: Error) => toast.error(e.message),
  });

  // Organizer verification — what unlocks creating paid events. Separate from
  // suspension: a user can be active-but-unverified (the default, free events
  // only) or verified-and-suspended (verification survives, but they can't
  // sign in at all). See User#verified?.
  const verify = useMutation({
    mutationFn: (id: string) => adminApi.verifyUser(id),
    onSuccess: () => {
      invalidate();
      toast.success(t("admin.toastVerified"));
    },
    onError: (e: Error) => toast.error(e.message),
  });

  const revokeRole = useMutation({
    mutationFn: (id: string) => adminApi.revokeStaffRole(id),
    onSuccess: () => {
      toast.success(t("admin.toastRoleRevoked"));
      invalidate();
    },
    onError: (e: Error) => toast.error(e.message),
  });

  const unverify = useMutation({
    mutationFn: (id: string) => adminApi.unverifyUser(id),
    onSuccess: () => {
      invalidate();
      toast.success(t("admin.toastUnverified"));
    },
    onError: (e: Error) => toast.error(e.message),
  });

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap gap-3">
        <form
          className="relative flex-1 min-w-[220px]"
          onSubmit={(e) => {
            e.preventDefault();
            setPage(1);
          }}
        >
          <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            value={q}
            onChange={(e) => {
              setQ(e.target.value);
              setPage(1);
            }}
            placeholder={t("admin.searchUsers")}
            aria-label={t("admin.searchUsers")}
            className="pl-9"
          />
        </form>

        <div className="flex gap-2">
          {(["all", "active", "suspended"] as const).map((value) => (
            <Button
              key={value}
              size="sm"
              variant={status === value ? "default" : "outline"}
              onClick={() => {
                setStatus(value);
                setPage(1);
              }}
            >
              {t(`admin.userStatus.${value}`)}
            </Button>
          ))}
        </div>
      </div>

      {query.isLoading && <p className="text-muted-foreground">{t("common.loading")}</p>}
      {query.isError && <p className="text-destructive">{(query.error as Error).message}</p>}

      {query.data && (
        <>
          <div className="overflow-x-auto rounded-xl border border-border">
            <table className="w-full text-sm">
              <thead className="bg-muted/50 text-left">
                <tr>
                  <th className="p-3 font-medium">{t("admin.colUser")}</th>
                  <th className="p-3 font-medium">{t("admin.colEvents")}</th>
                  <th className="p-3 font-medium">{t("admin.colJoined")}</th>
                  <th className="p-3 font-medium">{t("admin.colStatus")}</th>
                  <th className="p-3 font-medium text-right">{t("admin.colActions")}</th>
                </tr>
              </thead>
              <tbody>
                {query.data.users.map((u) => (
                  // The whole row opens the detail sheet. `<tr>` can't be a
                  // button, so this is the keyboard affordance instead — a
                  // focusable row with Enter/Space, rather than a "View"
                  // link in a sixth column that would be the only way in.
                  <tr
                    key={u.id}
                    tabIndex={0}
                    role="button"
                    aria-label={t("admin.viewUser", { email: u.email })}
                    className="cursor-pointer border-t border-border transition-colors hover:bg-muted/40 focus-visible:bg-muted/40 focus-visible:outline-none"
                    onClick={() => setDetailId(u.id)}
                    onKeyDown={(e) => {
                      if (e.key === "Enter" || e.key === " ") {
                        e.preventDefault();
                        setDetailId(u.id);
                      }
                    }}
                  >
                    <td className="p-3">
                      <p className="font-medium">{u.display_name ?? "—"}</p>
                      <p className="text-xs text-muted-foreground">{u.email}</p>
                    </td>
                    <td className="p-3">{u.events_count ?? 0}</td>
                    <td className="p-3 text-muted-foreground">{formatDate(u.created_at)}</td>
                    <td className="p-3">
                      <UserStatusBadges user={u} />
                    </td>
                    {/* Stops a click on the menu, or Enter on one of its
                        items, from also opening the detail sheet behind it. */}
                    <td
                      className="p-3 text-right"
                      onClick={(e) => e.stopPropagation()}
                      onKeyDown={(e) => e.stopPropagation()}
                    >
                      {u.admin ? (
                        <span className="text-xs text-muted-foreground">
                          {t("admin.noActionsForAdmin")}
                        </span>
                      ) : (
                        <UserActionsMenu
                          user={u}
                          busy={
                            verify.isPending ||
                            unverify.isPending ||
                            unsuspend.isPending ||
                            revokeRole.isPending
                          }
                          onVerify={() => verify.mutate(u.id)}
                          onUnverify={() => unverify.mutate(u.id)}
                          onUnsuspend={() => unsuspend.mutate(u.id)}
                          onRevokeRole={() => revokeRole.mutate(u.id)}
                          onDone={invalidate}
                        />
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          {query.data.users.length === 0 && (
            <p className="py-10 text-center text-muted-foreground">{t("admin.noUsers")}</p>
          )}

          <Pager
            page={page}
            totalPages={query.data.meta.total_pages}
            isFetching={query.isFetching}
            onChange={setPage}
          />
        </>
      )}

      {/* Outside the table, mounted once rather than per row — twenty-five
          sheets that are all closed still cost twenty-five subscriptions. */}
      <UserDetailSheet userId={detailId} onOpenChange={(open) => !open && setDetailId(null)} />
    </div>
  );
}

/**
 * The detail sheet, opened by clicking a row.
 *
 * Read-only on purpose. Everything that *changes* an account lives in the row's
 * Actions menu, and duplicating those controls here would mean two places to
 * keep in step with the server's rules about who may do what to whom — the
 * failure the capability matrix exists to avoid. This answers "who is this
 * account", which the twenty-five-row table has no width for.
 */
function UserDetailSheet({
  userId,
  onOpenChange,
}: {
  userId: string | null;
  onOpenChange: (open: boolean) => void;
}) {
  const { t } = useTranslation();

  const query = useQuery({
    queryKey: ["admin-user", userId],
    queryFn: () => adminApi.user(userId as string),
    // No request until a row is actually clicked. Without this the sheet would
    // fetch `/admin/users/null` on every render of the panel.
    enabled: Boolean(userId),
  });

  const user = query.data?.user;

  return (
    <Sheet open={Boolean(userId)} onOpenChange={onOpenChange}>
      <SheetContent className="w-full overflow-y-auto sm:max-w-md">
        <SheetHeader>
          <SheetTitle>{user?.display_name ?? user?.email ?? t("admin.userDetails")}</SheetTitle>
          <SheetDescription>{user?.email ?? t("common.loading")}</SheetDescription>
        </SheetHeader>

        {query.isLoading && (
          <p className="py-10 text-center text-muted-foreground">{t("common.loading")}</p>
        )}
        {query.isError && (
          <p className="py-10 text-center text-destructive">{(query.error as Error).message}</p>
        )}

        {user && (
          <div className="mt-6 space-y-6">
            <div className="flex flex-wrap gap-1.5">
              <UserStatusBadges user={user} />
            </div>

            <DetailSection title={t("admin.detailAccount")}>
              <DetailRow label={t("admin.detailJoined")} value={formatDate(user.created_at)} />
              <DetailRow
                label={t("admin.detailLastSeen")}
                value={
                  user.last_seen_at ? formatDateTime(user.last_seen_at) : t("admin.detailNeverSeen")
                }
                // The caveat belongs next to the number, not in a doc nobody
                // opens: this is the last authenticated request, recorded at
                // most hourly, and it is blank for anyone who hasn't been back
                // since the column shipped.
                hint={t("admin.detailLastSeenHint")}
              />
              <DetailRow
                label={t("admin.detailSignIn")}
                value={
                  user.provider === "google" ? t("admin.detailGoogle") : t("admin.detailEmail")
                }
              />
              <DetailRow
                label={t("admin.detailEmailVerified")}
                value={user.email_verified ? t("common.yes") : t("common.no")}
              />
            </DetailSection>

            {user.suspended && (
              <DetailSection title={t("admin.detailSuspension")}>
                <DetailRow
                  label={t("admin.detailSuspendedAt")}
                  value={user.suspended_at ? formatDateTime(user.suspended_at) : "—"}
                />
                <DetailRow
                  label={t("admin.detailSuspensionReason")}
                  value={user.suspension_reason || "—"}
                />
              </DetailSection>
            )}

            <DetailSection title={t("admin.detailActivity")}>
              <DetailRow
                label={t("admin.detailEventsCreated")}
                value={String(user.activity.events_count)}
              />
              <DetailRow
                label={t("admin.detailRegistrations")}
                value={String(user.activity.registrations_count)}
              />
              {/* One line per currency. Summing across them would be wrong in
                  a way that still looks like money — see the endpoint. */}
              {user.activity.paid.length === 0 ? (
                <DetailRow label={t("admin.detailPaid")} value={t("admin.detailNothingPaid")} />
              ) : (
                user.activity.paid.map((row) => (
                  <DetailRow
                    key={row.currency}
                    label={t("admin.detailPaid")}
                    value={formatPrice(row.gross_cents, row.currency)}
                    hint={
                      row.refunded_cents > 0
                        ? t("admin.detailRefunded", {
                            amount: formatPrice(row.refunded_cents, row.currency),
                          })
                        : undefined
                    }
                  />
                ))
              )}
            </DetailSection>
          </div>
        )}
      </SheetContent>
    </Sheet>
  );
}

function DetailSection({ title, children }: { title: string; children: ReactNode }) {
  return (
    <section className="space-y-1">
      <h3 className="text-xs font-medium uppercase tracking-wide text-muted-foreground">{title}</h3>
      <dl className="divide-y divide-border rounded-lg border border-border">{children}</dl>
    </section>
  );
}

function DetailRow({ label, value, hint }: { label: string; value: string; hint?: string }) {
  return (
    <div className="flex items-start justify-between gap-4 p-3">
      <dt className="text-sm text-muted-foreground">{label}</dt>
      <dd className="text-right text-sm">
        <span className="font-medium">{value}</span>
        {hint && <p className="mt-0.5 text-xs text-muted-foreground">{hint}</p>}
      </dd>
    </div>
  );
}

/**
 * The per-user actions, behind one "More" button.
 *
 * They were four side-by-side buttons in a `flex-wrap`, which at this table's
 * width wrapped onto a second and sometimes third line and made every row a
 * different height. A menu is also the safer shape: Suspend used to sit
 * immediately beside Verify, two clicks apart in a row of look-alike outline
 * buttons, and it is the one action here with a visible consequence for the
 * person on the other end. It now sits last, after a separator, styled as
 * destructive.
 *
 * **The dialogs are rendered outside the menu, not inside a
 * `DropdownMenuItem`.** A dropdown unmounts its content when it closes, so a
 * dialog trigger nested in an item takes the dialog down with it the instant
 * it is selected — the dialog flashes and disappears. Selecting an item here
 * therefore only sets `dialog`, and the three `AlertDialog`s below are
 * siblings of the menu, controlled by that state.
 *
 * `onCloseAutoFocus` is prevented for the same class of reason: Radix returns
 * focus to the trigger as the menu closes, which lands in the middle of the
 * dialog taking its own focus trap, and the two fight over it.
 */
function UserActionsMenu({
  user,
  busy,
  onVerify,
  onUnverify,
  onUnsuspend,
  onRevokeRole,
  onDone,
}: {
  user: ApiAdminUser;
  busy: boolean;
  onVerify: () => void;
  onUnverify: () => void;
  onUnsuspend: () => void;
  onRevokeRole: () => void;
  onDone: () => void;
}) {
  const { t } = useTranslation();
  const [dialog, setDialog] = useState<"suspend" | "role" | "impersonate" | null>(null);

  // Not offered for admins or suspended accounts — the server refuses both
  // (see Admin::ImpersonationsController#refusal_for), so hiding it spares a
  // pointless 422. `user.admin` is already false here (the caller's branch),
  // but the condition stays whole rather than relying on that from a distance.
  const canImpersonate = !user.admin && !user.suspended;

  return (
    <>
      <DropdownMenu>
        <DropdownMenuTrigger asChild>
          <Button size="sm" variant="outline" className="gap-1" disabled={busy}>
            {busy ? (
              <Loader2 className="h-3.5 w-3.5 animate-spin" />
            ) : (
              <MoreHorizontal className="h-3.5 w-3.5" />
            )}
            {t("admin.actions")}
          </Button>
        </DropdownMenuTrigger>

        <DropdownMenuContent align="end" onCloseAutoFocus={(e) => e.preventDefault()}>
          {/* Verification is orthogonal to suspension, so it stays available
              either way — vetting an organizer and letting them sign in are
              separate decisions. */}
          {user.verified ? (
            <DropdownMenuItem onSelect={onUnverify}>
              <ShieldOff className="mr-2 h-4 w-4" />
              {t("admin.unverify")}
            </DropdownMenuItem>
          ) : (
            <DropdownMenuItem onSelect={onVerify}>
              <BadgeCheck className="mr-2 h-4 w-4" />
              {t("admin.verify")}
            </DropdownMenuItem>
          )}

          {/* Staff membership. Revoking is immediate; granting raises a
              request for a second admin to sign, which is what applies it
              (D11). Admins are excluded in both directions — their role is
              managed from a console — but the caller already hides all of
              this for them. */}
          {user.staff_role ? (
            <DropdownMenuItem onSelect={onRevokeRole}>
              <ShieldOff className="mr-2 h-4 w-4" />
              {t("admin.revokeRole")}
            </DropdownMenuItem>
          ) : (
            <DropdownMenuItem onSelect={() => setDialog("role")}>
              <ShieldAlert className="mr-2 h-4 w-4" />
              {t("admin.proposeRole")}
            </DropdownMenuItem>
          )}

          {canImpersonate && (
            <DropdownMenuItem onSelect={() => setDialog("impersonate")}>
              <Eye className="mr-2 h-4 w-4" />
              {t("admin.impersonate")}
            </DropdownMenuItem>
          )}

          <DropdownMenuSeparator />

          {user.suspended ? (
            <DropdownMenuItem onSelect={onUnsuspend}>
              <RotateCcw className="mr-2 h-4 w-4" />
              {t("admin.unsuspend")}
            </DropdownMenuItem>
          ) : (
            <DropdownMenuItem
              onSelect={() => setDialog("suspend")}
              className="text-destructive focus:text-destructive"
            >
              <Ban className="mr-2 h-4 w-4" />
              {t("admin.suspend")}
            </DropdownMenuItem>
          )}
        </DropdownMenuContent>
      </DropdownMenu>

      <SuspendUserDialog
        user={user}
        open={dialog === "suspend"}
        onOpenChange={(next) => setDialog(next ? "suspend" : null)}
        onDone={onDone}
      />
      <ProposeRoleDialog
        user={user}
        open={dialog === "role"}
        onOpenChange={(next) => setDialog(next ? "role" : null)}
        onDone={onDone}
      />
      {canImpersonate && (
        <ImpersonateUserDialog
          user={user}
          open={dialog === "impersonate"}
          onOpenChange={(next) => setDialog(next ? "impersonate" : null)}
        />
      )}
    </>
  );
}

function UserStatusBadges({ user }: { user: ApiAdminUser }) {
  const { t } = useTranslation();
  return (
    <div className="flex flex-wrap gap-1.5">
      {/* Any staff role, not just admin. Before this a moderator looked
          identical to an ordinary participant here, which made "who is
          staff?" unanswerable without a production console — see D10. */}
      {(user.staff_role ?? (user.admin ? "admin" : null)) && (
        <Badge>{t(`admin.badgeRole.${user.staff_role ?? "admin"}`)}</Badge>
      )}
      {user.suspended ? (
        <Badge variant="destructive" title={user.suspension_reason ?? undefined}>
          {t("admin.badgeSuspended")}
        </Badge>
      ) : (
        <Badge variant="secondary">{t("admin.badgeActive")}</Badge>
      )}
      {/* Organizer verification (admin-granted, gates paid events) — distinct
          from the email badge below, which only reflects whether they clicked
          the link in their signup email. */}
      {user.verified && (
        <Badge variant="default" className="gap-1">
          <BadgeCheck className="h-3 w-3" /> {t("admin.badgeVerified")}
        </Badge>
      )}
      {!user.email_verified && <Badge variant="outline">{t("admin.badgeUnverified")}</Badge>}
    </div>
  );
}

/**
 * Proposes a staff role. **This does not grant it** — D11: the request goes
 * to the approvals queue and a *different* admin approving it is what applies
 * the role. The copy says so plainly, because a button that looks like it
 * assigned someone a role and didn't is worse than no button.
 *
 * `admin` is absent from the picker on purpose and the server refuses it
 * anyway: that role is granted from a console, so a stolen admin session
 * can't mint another admin.
 */
function ProposeRoleDialog({
  user,
  open,
  onOpenChange,
  onDone,
}: {
  user: ApiAdminUser;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onDone: () => void;
}) {
  const { t } = useTranslation();
  const [role, setRole] = useState<StaffRole>("support");
  const [reason, setReason] = useState("");

  const propose = useMutation({
    mutationFn: () =>
      staffApprovalsApi.request({
        action_name: "grant_staff_role",
        target_type: "User",
        target_id: user.id,
        payload: { staff_role: role },
        reason: reason.trim(),
      }),
    onSuccess: () => {
      setReason("");
      onOpenChange(false);
      onDone();
      toast.success(t("admin.toastRoleProposed"));
    },
    onError: (e: Error) => toast.error(e.message),
  });

  return (
    <AlertDialog open={open} onOpenChange={onOpenChange}>
      <AlertDialogContent>
        <AlertDialogHeader>
          <AlertDialogTitle>{t("admin.proposeRoleTitle", { email: user.email })}</AlertDialogTitle>
          <AlertDialogDescription>{t("admin.proposeRoleDesc")}</AlertDialogDescription>
        </AlertDialogHeader>

        <div className="space-y-4">
          <div className="space-y-2">
            <Label htmlFor={`role-${user.id}`}>{t("admin.proposeRoleLabel")}</Label>
            <Select value={role} onValueChange={(v) => setRole(v as StaffRole)}>
              <SelectTrigger id={`role-${user.id}`}>
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="support">{t("admin.badgeRole.support")}</SelectItem>
                <SelectItem value="moderator">{t("admin.badgeRole.moderator")}</SelectItem>
              </SelectContent>
            </Select>
          </div>

          <div className="space-y-2">
            <Label htmlFor={`role-reason-${user.id}`}>{t("admin.proposeRoleReason")}</Label>
            <Textarea
              id={`role-reason-${user.id}`}
              value={reason}
              onChange={(e) => setReason(e.target.value)}
              rows={3}
              maxLength={500}
              placeholder={t("admin.proposeRoleReasonPlaceholder")}
            />
          </div>
        </div>

        <AlertDialogFooter>
          <AlertDialogCancel>{t("common.cancel")}</AlertDialogCancel>
          <AlertDialogAction
            onClick={(e) => {
              // The dialog closes on its own onSuccess; let the mutation
              // decide, so a server refusal keeps the form and its reason.
              e.preventDefault();
              propose.mutate();
            }}
            disabled={propose.isPending || reason.trim().length === 0}
            className="gap-2"
          >
            {propose.isPending && <Loader2 className="h-4 w-4 animate-spin" />}
            {t("admin.confirmProposeRole")}
          </AlertDialogAction>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  );
}

function SuspendUserDialog({
  user,
  open,
  onOpenChange,
  onDone,
}: {
  user: ApiAdminUser;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onDone: () => void;
}) {
  const { t } = useTranslation();
  const [reason, setReason] = useState("");

  const suspend = useMutation({
    mutationFn: () => adminApi.suspendUser(user.id, reason.trim() || undefined),
    onSuccess: () => {
      setReason("");
      onOpenChange(false);
      onDone();
      toast.success(t("admin.toastSuspended"));
    },
    onError: (e: Error) => toast.error(e.message),
  });

  return (
    <AlertDialog open={open} onOpenChange={onOpenChange}>
      <AlertDialogContent>
        <AlertDialogHeader>
          <AlertDialogTitle>{t("admin.suspendTitle", { email: user.email })}</AlertDialogTitle>
          <AlertDialogDescription>{t("admin.suspendDesc")}</AlertDialogDescription>
        </AlertDialogHeader>

        <div className="space-y-2">
          <Label htmlFor={`reason-${user.id}`}>{t("admin.suspendReason")}</Label>
          <Textarea
            id={`reason-${user.id}`}
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            rows={3}
            maxLength={500}
            placeholder={t("admin.suspendReasonPlaceholder")}
          />
        </div>

        <AlertDialogFooter>
          <AlertDialogCancel>{t("common.cancel")}</AlertDialogCancel>
          <AlertDialogAction
            onClick={(e) => {
              // Radix closes on action by default, which under a controlled
              // `open` would discard a typed reason the moment the server
              // refused. The mutation owns closing, as in the other two.
              e.preventDefault();
              suspend.mutate();
            }}
            disabled={suspend.isPending}
            className="gap-2"
          >
            {suspend.isPending && <Loader2 className="h-4 w-4 animate-spin" />}
            {t("admin.confirmSuspend")}
          </AlertDialogAction>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  );
}

/**
 * Opening a staff support session — see docs/impersonation-design.md.
 *
 * The reason field is required (10–500 chars, enforced server-side too) and is
 * **quoted verbatim in the email the user receives**. The dialog says so
 * plainly, because that is the entire reason the field works: writing "checking
 * the publish error from ticket #412" takes four seconds, and writing it
 * knowing the organizer will read it is what makes idle curiosity feel like
 * what it is. Free text rather than a dropdown — a dropdown is a list of
 * excuses to click through.
 */
function ImpersonateUserDialog({
  user,
  open,
  onOpenChange,
}: {
  user: ApiAdminUser;
  open: boolean;
  onOpenChange: (open: boolean) => void;
}) {
  const { t } = useTranslation();
  const navigate = useNavigate();
  const { startImpersonation } = useAuth();
  const [reason, setReason] = useState("");

  const start = useMutation({
    mutationFn: () => startImpersonation(user.id, reason.trim()),
    onSuccess: () => {
      onOpenChange(false);
      setReason("");
      // Leave the admin console immediately. Staying would show a 404 shell —
      // require_admin! refuses an impersonation token — which reads as a
      // broken page rather than as the intended "you are someone else now".
      void navigate({ to: "/dashboard" });
    },
    onError: (e: Error) => toast.error(e.message),
  });

  const tooShort = reason.trim().length < 10;

  return (
    <AlertDialog open={open} onOpenChange={onOpenChange}>
      <AlertDialogContent>
        <AlertDialogHeader>
          <AlertDialogTitle>{t("admin.impersonateTitle", { email: user.email })}</AlertDialogTitle>
          <AlertDialogDescription>{t("admin.impersonateDesc")}</AlertDialogDescription>
        </AlertDialogHeader>

        <div className="space-y-2">
          <Label htmlFor={`imp-reason-${user.id}`}>{t("admin.impersonateReason")}</Label>
          <Textarea
            id={`imp-reason-${user.id}`}
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            rows={3}
            minLength={10}
            maxLength={500}
            placeholder={t("admin.impersonateReasonPlaceholder")}
          />
          <p className="text-xs text-muted-foreground">{t("admin.impersonateReasonNotice")}</p>
        </div>

        <AlertDialogFooter>
          <AlertDialogCancel>{t("common.cancel")}</AlertDialogCancel>
          <AlertDialogAction
            onClick={(e) => {
              // Radix closes the dialog on action by default; the mutation
              // owns closing so a failed start leaves the typed reason intact.
              e.preventDefault();
              start.mutate();
            }}
            disabled={start.isPending || tooShort}
            className="gap-2"
          >
            {start.isPending && <Loader2 className="h-4 w-4 animate-spin" />}
            {t("admin.confirmImpersonate")}
          </AlertDialogAction>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  );
}

// ─── Events ───────────────────────────────────────────────────────────────────

function EventsPanel() {
  const { t } = useTranslation();
  const queryClient = useQueryClient();

  const [q, setQ] = useState("");
  const [status, setStatus] = useState<"all" | "published" | "draft">("all");
  const [page, setPage] = useState(1);

  const query = useQuery({
    queryKey: ["admin-events", q, status, page],
    queryFn: () => adminApi.events({ q, status, page, perPage: PER_PAGE }),
    placeholderData: keepPreviousData,
  });

  const invalidate = () => queryClient.invalidateQueries({ queryKey: ["admin-events"] });

  const unpublish = useMutation({
    mutationFn: (id: string) => adminApi.unpublishEvent(id),
    onSuccess: () => {
      invalidate();
      toast.success(t("admin.toastUnpublished"));
    },
    onError: (e: Error) => toast.error(e.message),
  });

  // No confirmation dialog, unlike suspending — reversing course should be
  // low-friction; suspending (which emails the owner and locks the event down)
  // should not be. Mirrors unsuspendUser's lack of a confirm dialog.
  const unsuspend = useMutation({
    mutationFn: (id: string) => adminApi.unsuspendEvent(id),
    onSuccess: () => {
      invalidate();
      toast.success(t("admin.toastEventUnsuspended"));
    },
    onError: (e: Error) => toast.error(e.message),
  });

  const remove = useMutation({
    mutationFn: (id: string) => adminApi.deleteEvent(id),
    onSuccess: () => {
      invalidate();
      toast.success(t("admin.toastEventDeleted"));
    },
    // The API refuses deletion when paid registrations exist, which surfaces
    // here as an ApiError with an explanatory message.
    onError: (e: Error) => toast.error(e.message),
  });

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap gap-3">
        <div className="relative flex-1 min-w-[220px]">
          <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            value={q}
            onChange={(e) => {
              setQ(e.target.value);
              setPage(1);
            }}
            placeholder={t("admin.searchEvents")}
            aria-label={t("admin.searchEvents")}
            className="pl-9"
          />
        </div>

        <div className="flex gap-2">
          {(["all", "published", "draft"] as const).map((value) => (
            <Button
              key={value}
              size="sm"
              variant={status === value ? "default" : "outline"}
              onClick={() => {
                setStatus(value);
                setPage(1);
              }}
            >
              {t(`admin.eventStatus.${value}`)}
            </Button>
          ))}
        </div>
      </div>

      {query.isLoading && <p className="text-muted-foreground">{t("common.loading")}</p>}
      {query.isError && <p className="text-destructive">{(query.error as Error).message}</p>}

      {query.data && (
        <>
          <div className="overflow-x-auto rounded-xl border border-border">
            <table className="w-full text-sm">
              <thead className="bg-muted/50 text-left">
                <tr>
                  <th className="p-3 font-medium">{t("admin.colEvent")}</th>
                  <th className="p-3 font-medium">{t("admin.colOrganizer")}</th>
                  <th className="p-3 font-medium">{t("admin.colRegistrations")}</th>
                  <th className="p-3 font-medium">{t("admin.colStatus")}</th>
                  <th className="p-3 font-medium text-right">{t("admin.colActions")}</th>
                </tr>
              </thead>
              <tbody>
                {query.data.events.map((ev) => (
                  <tr key={ev.id} className="border-t border-border">
                    <td className="p-3">
                      <p className="font-medium">{ev.title}</p>
                      <p className="text-xs text-muted-foreground">
                        {categoryLabel(ev.category)} · {formatDate(ev.start_at)} ·{" "}
                        {formatPrice(ev.price_cents, ev.currency)}
                      </p>
                    </td>
                    <td className="p-3">
                      <p className="text-xs">{ev.creator.display_name ?? ev.creator.email}</p>
                      {ev.creator.suspended && (
                        <Badge variant="destructive" className="mt-1">
                          {t("admin.badgeSuspended")}
                        </Badge>
                      )}
                    </td>
                    <td className="p-3">{ev.registrations_count}</td>
                    <td className="p-3">
                      <div className="flex flex-wrap gap-1">
                        <Badge variant={ev.is_published ? "secondary" : "outline"}>
                          {ev.is_published ? t("admin.badgePublished") : t("admin.badgeDraft")}
                        </Badge>
                        {/* Suspended is orthogonal to published/draft — a suspended
                            event is always unpublished too, but showing both
                            badges makes clear *why* (moderation, not just a
                            draft) and that unpublishing it back yourself
                            won't work. */}
                        {ev.suspended && (
                          <Badge variant="destructive">{t("admin.badgeEventSuspended")}</Badge>
                        )}
                      </div>
                    </td>
                    <td className="p-3">
                      <div className="flex flex-wrap justify-end gap-2">
                        {ev.is_published && !ev.suspended && (
                          <Button
                            size="sm"
                            variant="outline"
                            className="gap-1"
                            disabled={unpublish.isPending}
                            onClick={() => unpublish.mutate(ev.id)}
                          >
                            <EyeOff className="h-3.5 w-3.5" />
                            {t("admin.unpublish")}
                          </Button>
                        )}
                        {ev.suspended ? (
                          <Button
                            size="sm"
                            variant="outline"
                            className="gap-1"
                            disabled={unsuspend.isPending}
                            onClick={() => unsuspend.mutate(ev.id)}
                          >
                            <RotateCcw className="h-3.5 w-3.5" />
                            {t("admin.unsuspendEvent")}
                          </Button>
                        ) : (
                          <SuspendEventDialog event={ev} onDone={invalidate} />
                        )}
                        <DeleteEventDialog
                          event={ev}
                          isPending={remove.isPending}
                          onConfirm={() => remove.mutate(ev.id)}
                        />
                      </div>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          {query.data.events.length === 0 && (
            <p className="py-10 text-center text-muted-foreground">{t("admin.noEvents")}</p>
          )}

          <Pager
            page={page}
            totalPages={query.data.meta.total_pages}
            isFetching={query.isFetching}
            onChange={setPage}
          />
        </>
      )}
    </div>
  );
}

// Mirrors SuspendUserDialog almost exactly, with one deliberate difference:
// the reason is required (the API rejects a blank one, and it's emailed to
// the owner verbatim — see EventMailer#suspended), so the confirm button stays
// disabled until something is typed, rather than allowing an empty reason
// through like suspending a user does.
function SuspendEventDialog({ event, onDone }: { event: ApiAdminEvent; onDone: () => void }) {
  const { t } = useTranslation();
  const [reason, setReason] = useState("");

  const suspend = useMutation({
    mutationFn: () => adminApi.suspendEvent(event.id, reason.trim()),
    onSuccess: () => {
      setReason("");
      onDone();
      toast.success(t("admin.toastEventSuspended"));
    },
    onError: (e: Error) => toast.error(e.message),
  });

  return (
    <AlertDialog>
      <AlertDialogTrigger asChild>
        <Button size="sm" variant="destructive" className="gap-1">
          <Ban className="h-3.5 w-3.5" />
          {t("admin.suspendEvent")}
        </Button>
      </AlertDialogTrigger>
      <AlertDialogContent>
        <AlertDialogHeader>
          <AlertDialogTitle>
            {t("admin.suspendEventTitle", { title: event.title })}
          </AlertDialogTitle>
          <AlertDialogDescription>{t("admin.suspendEventDesc")}</AlertDialogDescription>
        </AlertDialogHeader>

        <div className="space-y-2">
          <Label htmlFor={`suspend-reason-${event.id}`}>{t("admin.suspendEventReason")}</Label>
          <Textarea
            id={`suspend-reason-${event.id}`}
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            rows={3}
            maxLength={500}
            placeholder={t("admin.suspendEventReasonPlaceholder")}
          />
        </div>

        <AlertDialogFooter>
          <AlertDialogCancel>{t("common.cancel")}</AlertDialogCancel>
          <AlertDialogAction
            onClick={() => suspend.mutate()}
            disabled={suspend.isPending || reason.trim().length === 0}
            className="gap-2"
          >
            {suspend.isPending && <Loader2 className="h-4 w-4 animate-spin" />}
            {t("admin.confirmSuspendEvent")}
          </AlertDialogAction>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  );
}

function DeleteEventDialog({
  event,
  isPending,
  onConfirm,
}: {
  event: ApiAdminEvent;
  isPending: boolean;
  onConfirm: () => void;
}) {
  const { t } = useTranslation();

  return (
    <AlertDialog>
      <AlertDialogTrigger asChild>
        <Button size="sm" variant="destructive" className="gap-1">
          <Trash2 className="h-3.5 w-3.5" />
          {t("common.delete")}
        </Button>
      </AlertDialogTrigger>
      <AlertDialogContent>
        <AlertDialogHeader>
          <AlertDialogTitle>{t("admin.deleteEventTitle", { title: event.title })}</AlertDialogTitle>
          <AlertDialogDescription>
            {t("admin.deleteEventDesc", { count: event.registrations_count })}
          </AlertDialogDescription>
        </AlertDialogHeader>
        <AlertDialogFooter>
          <AlertDialogCancel>{t("common.cancel")}</AlertDialogCancel>
          <AlertDialogAction onClick={onConfirm} disabled={isPending} className="gap-2">
            {isPending && <Loader2 className="h-4 w-4 animate-spin" />}
            {t("admin.confirmDelete")}
          </AlertDialogAction>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  );
}

// ─── Shared ───────────────────────────────────────────────────────────────────

function Pager({
  page,
  totalPages,
  isFetching,
  onChange,
}: {
  page: number;
  totalPages: number;
  isFetching: boolean;
  onChange: (page: number) => void;
}) {
  const { t } = useTranslation();
  if (totalPages <= 1) return null;

  return (
    <nav className="flex items-center justify-center gap-3" aria-label={t("admin.paginationLabel")}>
      <Button
        variant="outline"
        size="sm"
        disabled={page <= 1 || isFetching}
        onClick={() => onChange(Math.max(1, page - 1))}
        className="gap-1"
      >
        <ChevronLeft className="h-4 w-4" />
        {t("common.previous")}
      </Button>
      <span className="text-sm text-muted-foreground" aria-live="polite">
        {t("eventsList.pageOf", { page, totalPages })}
      </span>
      <Button
        variant="outline"
        size="sm"
        disabled={page >= totalPages || isFetching}
        onClick={() => onChange(Math.min(totalPages, page + 1))}
        className="gap-1"
      >
        {t("common.next")}
        <ChevronRight className="h-4 w-4" />
      </Button>
    </nav>
  );
}
