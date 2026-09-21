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
import { useState } from "react";
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
} from "lucide-react";
import { toast } from "sonner";
import { useTranslation } from "react-i18next";

import { adminApi, type ApiAdminUser, type ApiAdminEvent } from "@/lib/api-client";
import { useAuth } from "@/lib/use-auth";
import { SiteHeader } from "@/components/site-header";
import { AdminOverview } from "@/components/admin-overview";
import { AdminSupport } from "@/components/admin-support";
import { AdminEventReports } from "@/components/admin-event-reports";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { Tabs, TabsList, TabsTrigger, TabsContent } from "@/components/ui/tabs";
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
import { formatDate, formatPrice, categoryLabel } from "@/lib/event-utils";

const PER_PAGE = 25;

const ADMIN_TABS = ["overview", "users", "events", "reports", "support"] as const;
type AdminTab = (typeof ADMIN_TABS)[number];

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

  if (user && !user.admin) {
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
          value={tab ?? "overview"}
          onValueChange={(value) => navigate({ search: { tab: value as AdminTab }, replace: true })}
          className="mt-8"
        >
          <TabsList>
            <TabsTrigger value="overview">
              <LayoutDashboard className="h-4 w-4 mr-1.5" /> {t("admin.tabOverview")}
            </TabsTrigger>
            <TabsTrigger value="users">{t("admin.tabUsers")}</TabsTrigger>
            <TabsTrigger value="events">{t("admin.tabEvents")}</TabsTrigger>
            <TabsTrigger value="reports">{t("admin.tabReports")}</TabsTrigger>
            <TabsTrigger value="support">{t("admin.tabSupport")}</TabsTrigger>
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
                  <tr key={u.id} className="border-t border-border">
                    <td className="p-3">
                      <p className="font-medium">{u.display_name ?? "—"}</p>
                      <p className="text-xs text-muted-foreground">{u.email}</p>
                    </td>
                    <td className="p-3">{u.events_count ?? 0}</td>
                    <td className="p-3 text-muted-foreground">{formatDate(u.created_at)}</td>
                    <td className="p-3">
                      <UserStatusBadges user={u} />
                    </td>
                    <td className="p-3 text-right">
                      {u.admin ? (
                        <span className="text-xs text-muted-foreground">
                          {t("admin.noActionsForAdmin")}
                        </span>
                      ) : (
                        <div className="flex flex-wrap justify-end gap-2">
                          {/* Verification is orthogonal to suspension, so it
                              stays available either way — vetting an
                              organizer and letting them sign in are separate
                              decisions. */}
                          {u.verified ? (
                            <Button
                              size="sm"
                              variant="outline"
                              className="gap-1"
                              disabled={unverify.isPending}
                              onClick={() => unverify.mutate(u.id)}
                            >
                              <ShieldOff className="h-3.5 w-3.5" />
                              {t("admin.unverify")}
                            </Button>
                          ) : (
                            <Button
                              size="sm"
                              variant="outline"
                              className="gap-1"
                              disabled={verify.isPending}
                              onClick={() => verify.mutate(u.id)}
                            >
                              <BadgeCheck className="h-3.5 w-3.5" />
                              {t("admin.verify")}
                            </Button>
                          )}

                          {u.suspended ? (
                            <Button
                              size="sm"
                              variant="outline"
                              className="gap-1"
                              disabled={unsuspend.isPending}
                              onClick={() => unsuspend.mutate(u.id)}
                            >
                              <RotateCcw className="h-3.5 w-3.5" />
                              {t("admin.unsuspend")}
                            </Button>
                          ) : (
                            <SuspendUserDialog user={u} onDone={invalidate} />
                          )}

                          {/* Not offered for admins or suspended accounts —
                              the server refuses both (see
                              Admin::ImpersonationsController#refusal_for), so
                              hiding the button just spares a pointless 422. */}
                          {!u.admin && !u.suspended && <ImpersonateUserDialog user={u} />}
                        </div>
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
    </div>
  );
}

function UserStatusBadges({ user }: { user: ApiAdminUser }) {
  const { t } = useTranslation();
  return (
    <div className="flex flex-wrap gap-1.5">
      {user.admin && <Badge>{t("admin.badgeAdmin")}</Badge>}
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

function SuspendUserDialog({ user, onDone }: { user: ApiAdminUser; onDone: () => void }) {
  const { t } = useTranslation();
  const [reason, setReason] = useState("");

  const suspend = useMutation({
    mutationFn: () => adminApi.suspendUser(user.id, reason.trim() || undefined),
    onSuccess: () => {
      setReason("");
      onDone();
      toast.success(t("admin.toastSuspended"));
    },
    onError: (e: Error) => toast.error(e.message),
  });

  return (
    <AlertDialog>
      <AlertDialogTrigger asChild>
        <Button size="sm" variant="destructive" className="gap-1">
          <Ban className="h-3.5 w-3.5" />
          {t("admin.suspend")}
        </Button>
      </AlertDialogTrigger>
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
            onClick={() => suspend.mutate()}
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
function ImpersonateUserDialog({ user }: { user: ApiAdminUser }) {
  const { t } = useTranslation();
  const navigate = useNavigate();
  const { startImpersonation } = useAuth();
  const [open, setOpen] = useState(false);
  const [reason, setReason] = useState("");

  const start = useMutation({
    mutationFn: () => startImpersonation(user.id, reason.trim()),
    onSuccess: () => {
      setOpen(false);
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
    <AlertDialog open={open} onOpenChange={setOpen}>
      <AlertDialogTrigger asChild>
        <Button size="sm" variant="outline" className="gap-1">
          <Eye className="h-3.5 w-3.5" />
          {t("admin.impersonate")}
        </Button>
      </AlertDialogTrigger>
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
