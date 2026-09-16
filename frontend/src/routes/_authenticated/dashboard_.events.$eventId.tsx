import { createFileRoute, Link, useNavigate } from "@tanstack/react-router";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { useState, useEffect } from "react";
import {
  ArrowLeft,
  CalendarDays,
  ExternalLink,
  MapPin,
  Milestone,
  Users,
  DollarSign,
  Trash2,
  Check,
  X,
  Download,
  Loader2,
  Palette,
  QrCode,
  ClipboardList,
  MessageSquare,
  Rocket,
  EyeOff,
  Hourglass,
  Award,
  ScanLine,
  Trophy,
  Search,
  Undo2,
  History,
  UserMinus,
  PencilLine,
  UserPlus,
  Ban,
  UserCheck,
  Shield,
  LogOut,
  UsersRound,
  Settings,
  ChevronDown,
} from "lucide-react";
import { toast } from "sonner";
import { useTranslation } from "react-i18next";
import {
  eventsApi,
  registrationsApi,
  waitlistApi,
  surveyResponsesApi,
  eventPlansApi,
  type ApiSurveyResponse,
  type ApiEventActivity,
} from "@/lib/api-client";
import { useAuth } from "@/lib/use-auth";
import { SiteHeader } from "@/components/site-header";
import { EventQRCode } from "@/components/event-qr-code";
import { EventDetailsEditor } from "@/components/event-details-editor";
import { ImageUpload } from "@/components/image-upload";
import { CertificateTemplateUpload } from "@/components/certificate-template-upload";
import { PlanPaymentPanel } from "@/components/plan-payment-panel";
import { CheckInScanner } from "@/components/check-in-scanner";
import { ResultsManager } from "@/components/results-manager";
import { MembersTab } from "@/components/members-tab";
import { ListPager } from "@/components/list-pager";
import { BibNumberField } from "@/components/bib-number-field";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Label } from "@/components/ui/label";
import { Input } from "@/components/ui/input";
import { Tabs, TabsList, TabsTrigger, TabsContent } from "@/components/ui/tabs";
import {
  DropdownMenu,
  DropdownMenuTrigger,
  DropdownMenuContent,
  DropdownMenuItem,
} from "@/components/ui/dropdown-menu";
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
  formatDateTime,
  formatDate,
  formatPrice,
  categoryLabel,
  googleMapsViewUrl,
  memberRoleLabel,
} from "@/lib/event-utils";
import { downloadICS } from "@/lib/ics";
import { cn } from "@/lib/utils";
import i18n from "@/lib/i18n";

export const Route = createFileRoute("/_authenticated/dashboard_/events/$eventId")({
  head: () => ({ meta: [{ title: "Manage event — Rally" }] }),
  component: ManageEvent,
});

const PRESET_COLORS = [
  "#6366f1",
  "#8b5cf6",
  "#ec4899",
  "#ef4444",
  "#f97316",
  "#eab308",
  "#22c55e",
  "#06b6d4",
  "#0ea5e9",
  "#64748b",
];

/** One line per changed field for an `update_event_details` entry, or a
 * single line for `remove_participant` — see EventActivity's metadata shape
 * on the backend (Api::V1::EventsController#log_event_details_changes /
 * #destroy). Pure function (no hooks), so it uses the i18n default export
 * directly rather than useTranslation(), same pattern as event-utils.ts. */
function describeEventActivity(activity: ApiEventActivity, currency: string): string[] {
  if (activity.action === "remove_participant") {
    const name =
      (activity.metadata.participant_name as string | null) ||
      i18n.t("manageEvent.participantFallback");
    return [i18n.t("manageEvent.activityRemovedParticipant", { name })];
  }

  if (activity.action === "invite_member") {
    const email = activity.metadata.email as string;
    const role = memberRoleLabel(activity.metadata.role as string);
    return [i18n.t("manageEvent.activityInvitedMember", { email, role })];
  }

  if (activity.action === "revoke_invitation") {
    const email = activity.metadata.email as string;
    return [i18n.t("manageEvent.activityRevokedInvitation", { email })];
  }

  if (activity.action === "member_joined") {
    const role = memberRoleLabel(activity.metadata.role as string);
    return [i18n.t("manageEvent.activityMemberJoined", { role })];
  }

  if (activity.action === "remove_member") {
    const name =
      (activity.metadata.member_name as string | null) ||
      (activity.metadata.member_email as string | null) ||
      i18n.t("manageEvent.memberFallback");
    return activity.metadata.self_removal
      ? [i18n.t("manageEvent.activityLeftTeam")]
      : [i18n.t("manageEvent.activityRemovedMember", { name })];
  }

  if (activity.action === "change_member_role") {
    const name =
      (activity.metadata.member_name as string | null) ||
      (activity.metadata.member_email as string | null) ||
      i18n.t("manageEvent.memberFallback");
    const from = memberRoleLabel(activity.metadata.from as string);
    const to = memberRoleLabel(activity.metadata.to as string);
    return [i18n.t("manageEvent.activityChangedMemberRole", { name, from, to })];
  }

  const lines: string[] = [];
  const priceChange = activity.metadata.price_cents as { from: number; to: number } | undefined;
  if (priceChange) {
    lines.push(
      i18n.t("manageEvent.activityPriceChanged", {
        from: formatPrice(priceChange.from, currency),
        to: formatPrice(priceChange.to, currency),
      }),
    );
  }
  const startChange = activity.metadata.start_at as { from: string; to: string } | undefined;
  if (startChange) {
    lines.push(
      i18n.t("manageEvent.activityStartChanged", {
        from: formatDateTime(startChange.from),
        to: formatDateTime(startChange.to),
      }),
    );
  }
  const endChange = activity.metadata.end_at as { from: string; to: string } | undefined;
  if (endChange) {
    lines.push(
      i18n.t("manageEvent.activityEndChanged", {
        from: formatDateTime(endChange.from),
        to: formatDateTime(endChange.to),
      }),
    );
  }
  return lines;
}

/** Icon per EventActivity action — a small lookup rather than a growing
 * ternary chain, now that there are 7 action types. `remove_member` gets its
 * own icon for a self-removal ("left the team") vs. being removed by the
 * owner, since those read very differently even though it's one action. */
function ActivityIcon({ activity }: { activity: ApiEventActivity }) {
  const cls = "h-4 w-4 text-muted-foreground";
  switch (activity.action) {
    case "invite_member":
      return <UserPlus className={cls} />;
    case "revoke_invitation":
      return <Ban className={cls} />;
    case "member_joined":
      return <UserCheck className={cls} />;
    case "change_member_role":
      return <Shield className={cls} />;
    case "remove_member":
      return activity.metadata.self_removal ? (
        <LogOut className={cls} />
      ) : (
        <UserMinus className={cls} />
      );
    case "remove_participant":
      return <UserMinus className={cls} />;
    default:
      return <PencilLine className={cls} />;
  }
}

/** ISO instant -> the "YYYY-MM-DDTHH:mm" a datetime-local input expects, in
 *  the viewer's own zone. Returns "" for null so the input stays controlled. */
function toDateTimeLocal(iso: string | null): string {
  if (!iso) return "";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  // Shift by the zone offset before slicing, because toISOString() is UTC and
  // the input renders whatever string it is given as local time — feeding it
  // raw UTC would display a deadline hours away from the one that was set.
  const local = new Date(d.getTime() - d.getTimezoneOffset() * 60_000);
  return local.toISOString().slice(0, 16);
}

/** Tabs that render a page of the participant list. Membership decides
 *  whether the list query runs at all — see participantsQuery's `enabled`. */
const LIST_TABS = ["participants", "checkin", "results"];
const PER_PAGE = 25;
/** Long enough that typing a name doesn't fire a request per keystroke,
 *  short enough that the list doesn't feel stuck. */
const SEARCH_DEBOUNCE_MS = 300;

/** Underline styling for the nested Setup tabs, overriding the shadcn default
 *  at the call site so `components/ui/tabs.tsx` stays vendored/untouched. The
 *  parent bar keeps the filled pill; this one is the secondary level, and the
 *  two must not look alike or the nesting is invisible. `-mb-px` pulls each
 *  trigger's bottom border onto the list's, so the active underline sits in
 *  the rule rather than below it. */
const SETUP_TABS_LIST_CLASS =
  "h-auto w-full flex-wrap justify-start gap-6 rounded-none border-b border-border bg-transparent p-0";
/** Active state is colour + underline only, deliberately not a weight change:
 *  bolding the label widens it and shunts every tab after it sideways. */
const SETUP_TAB_TRIGGER_CLASS =
  "-mb-px rounded-none border-b-2 border-transparent bg-transparent px-0 pb-3 pt-0 shadow-none " +
  "hover:text-foreground data-[state=active]:border-primary data-[state=active]:bg-transparent " +
  "data-[state=active]:text-foreground data-[state=active]:shadow-none focus-visible:ring-offset-0";

function ManageEvent() {
  const { eventId } = Route.useParams();
  const { t } = useTranslation();
  const { user } = useAuth();
  const navigate = useNavigate();
  const queryClient = useQueryClient();

  // Branding local state — undefined = not yet synced from server
  const [brandColor, setBrandColor] = useState<string | null>(null);
  const [bannerUrl, setBannerUrl] = useState<string | null | undefined>(undefined);
  const [logoUrl, setLogoUrl] = useState<string | null | undefined>(undefined);
  const [certificateTemplateUrl, setCertificateTemplateUrl] = useState<string | null | undefined>(
    undefined,
  );
  // datetime-local wants "YYYY-MM-DDTHH:mm" in *local* time, while the API
  // speaks ISO 8601 in UTC — so this is held as the input's own string and
  // converted at each boundary rather than kept as a Date.
  const [registrationClosesAt, setRegistrationClosesAt] = useState<string | undefined>(undefined);

  // Declared here, above the queries that read it. "participants" is always
  // permitted (panelVisibility.participants is unconditional), so the initial
  // tab needs nothing from the role — which is what lets it sit above `can`.
  const [tab, setTab] = useState<string>("participants");

  // One page/search pair shared by the three list tabs. They show the same
  // underlying rows, so carrying separate state per tab would mean three
  // near-identical queries and three caches to invalidate after a check-in.
  const [listPage, setListPage] = useState(1);
  const [listSearch, setListSearch] = useState("");
  const [debouncedSearch, setDebouncedSearch] = useState("");

  useEffect(() => {
    const id = setTimeout(() => setDebouncedSearch(listSearch), SEARCH_DEBOUNCE_MS);
    return () => clearTimeout(id);
  }, [listSearch]);

  // Page 1 whenever the search changes — otherwise searching from page 4 lands
  // on page 4 of a shorter result set, which usually means an empty table.
  useEffect(() => {
    setListPage(1);
  }, [debouncedSearch]);

  // And whenever the tab changes: page 3 of Participants is not a meaningful
  // starting point for Check-in.
  useEffect(() => {
    setListPage(1);
    setListSearch("");
  }, [tab]);

  const eventQuery = useQuery({
    queryKey: ["event", eventId],
    queryFn: async () => {
      const { event } = await eventsApi.get(eventId);
      return event;
    },
  });

  const ev = eventQuery.data;

  // Sync local branding state on first load
  if (ev && brandColor === null) setBrandColor(ev.brand_color ?? "#6366f1");
  if (ev && bannerUrl === undefined) setBannerUrl(ev.banner_url ?? null);
  if (ev && logoUrl === undefined) setLogoUrl(ev.logo_url ?? null);
  if (ev && certificateTemplateUrl === undefined) {
    setCertificateTemplateUrl(ev.certificate_template_url ?? null);
  }
  if (ev && registrationClosesAt === undefined) {
    setRegistrationClosesAt(toDateTimeLocal(ev.registration_closes_at));
  }

  // Counts and revenue for the stat cards. Always loaded, because those cards
  // sit above the tabs and are visible whichever one is open — but it's one
  // aggregate query, not every registration.
  const summaryQuery = useQuery({
    queryKey: ["event-registration-summary", eventId],
    queryFn: () => registrationsApi.summary(eventId).then((r) => r.summary),
  });

  // One page of participants, for whichever list tab is open. `enabled` is the
  // answer to "don't load all participants until we get into this tab": on
  // Setup or Activity this never fires at all.
  const participantsQuery = useQuery({
    // `tab` is deliberately NOT in the key: the request doesn't vary by tab,
    // only whether it runs does. Keying on it gave Participants, Check-in and
    // Results three cache entries holding the same page, so switching tabs
    // refetched data already in memory.
    queryKey: ["event-participants", eventId, listPage, debouncedSearch],
    enabled: LIST_TABS.includes(tab),
    // Keeps the previous page on screen while the next one loads, so paging
    // doesn't flash an empty table.
    placeholderData: (prev) => prev,
    queryFn: () =>
      registrationsApi.forEvent(eventId, {
        page: listPage,
        perPage: PER_PAGE,
        q: debouncedSearch,
      }),
  });

  const surveyResponsesQuery = useQuery({
    queryKey: ["survey-responses", eventId],
    enabled: !!ev?.survey_id,
    queryFn: () => surveyResponsesApi.forEvent(eventId),
  });

  const waitlistQuery = useQuery({
    queryKey: ["event-waitlist", eventId],
    queryFn: () => waitlistApi.forEvent(eventId).then((r) => r.waitlist_entries),
  });

  // Organizer-only history of participant removals and price/date changes —
  // see EventActivity on the backend.
  const activityQuery = useQuery({
    queryKey: ["event-activity", eventId],
    queryFn: () => eventsApi.activity(eventId).then((r) => r.activities),
  });

  const setPayment = useMutation({
    mutationFn: async ({ id, status, amount }: { id: string; status: string; amount: number }) => {
      await registrationsApi.updatePayment(id, status, status === "paid" ? amount : 0);
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["event-participants", eventId] });
      toast.success(t("manageEvent.toastPaymentUpdated"));
    },
    onError: (e: any) => toast.error(e.message),
  });

  // Not `invalidateParticipants` — a bib doesn't change any figure on the
  // summary cards, and refetching those on every keystroke-sized edit would
  // be two requests where one will do.
  const setBib = useMutation({
    mutationFn: ({ id, bib }: { id: string; bib: string | null }) =>
      registrationsApi.setBibNumber(id, bib),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["event-participants", eventId] });
    },
    onError: (e: any) => toast.error(e.message),
  });

  const removeParticipant = useMutation({
    mutationFn: (id: string) => registrationsApi.remove(id),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["event-participants", eventId] });
      queryClient.invalidateQueries({ queryKey: ["event-activity", eventId] });
      toast.success(t("manageEvent.toastParticipantRemoved"));
    },
    onError: (e: any) => toast.error(e.message),
  });

  // Both, always. The stat cards moved to their own aggregate query, so
  // invalidating only the list would update the row an organizer just checked
  // in while leaving the "checked in" and revenue cards showing stale figures
  // — the sort of divergence nobody reports because each half looks right.
  const invalidateParticipants = () => {
    queryClient.invalidateQueries({ queryKey: ["event-participants", eventId] });
    queryClient.invalidateQueries({ queryKey: ["event-registration-summary", eventId] });
  };

  const checkIn = useMutation({
    mutationFn: (id: string) => registrationsApi.checkIn(id),
    onSuccess: (data) => {
      invalidateParticipants();
      if (!data.already_checked_in)
        toast.success(
          t("checkIn.checkedInToast", {
            name: data.registration.profile?.display_name || t("checkIn.unnamedParticipant"),
          }),
        );
    },
    onError: (e: any) => toast.error(e.message),
  });

  const undoCheckIn = useMutation({
    mutationFn: (id: string) => registrationsApi.undoCheckIn(id),
    onSuccess: () => {
      invalidateParticipants();
      toast.success(t("checkIn.undoneToast"));
    },
    onError: (e: any) => toast.error(e.message),
  });

  const [exportingCsv, setExportingCsv] = useState(false);
  const handleExportCsv = async () => {
    setExportingCsv(true);
    try {
      await registrationsApi.exportCsv(eventId);
    } catch (e: any) {
      toast.error(e.message || t("manageEvent.exportCsvError"));
    } finally {
      setExportingCsv(false);
    }
  };

  const saveBranding = useMutation({
    mutationFn: () =>
      eventsApi.update(eventId, {
        brand_color: brandColor ?? "#6366f1",
        banner_url: bannerUrl ?? null,
        logo_url: logoUrl ?? null,
      }),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["event", eventId] });
      queryClient.invalidateQueries({ queryKey: ["public-event", eventId] });
      toast.success(t("manageEvent.toastBrandingSaved"));
    },
    onError: (e: any) => toast.error(e.message),
  });

  const saveCertificateTemplate = useMutation({
    mutationFn: () =>
      eventsApi.update(eventId, { certificate_template_url: certificateTemplateUrl ?? null }),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["event", eventId] });
      toast.success(t("manageEvent.toastCertificateSaved"));
    },
    onError: (e: any) => toast.error(e.message),
  });

  const saveRegistrationDeadline = useMutation({
    mutationFn: () =>
      eventsApi.update(eventId, {
        // Empty input clears the deadline. Sent as an absolute ISO instant so
        // the server never has to guess which zone the organizer meant.
        registration_closes_at: registrationClosesAt
          ? new Date(registrationClosesAt).toISOString()
          : null,
      }),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["event", eventId] });
      toast.success(t("manageEvent.toastDeadlineSaved"));
    },
    onError: (e: any) => toast.error(e.message),
  });

  const deleteEvent = useMutation({
    mutationFn: () => eventsApi.delete(eventId),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["my-events"] });
      toast.success(t("manageEvent.toastEventDeleted"));
      navigate({ to: "/dashboard" });
    },
    onError: (e: any) => toast.error(e.message),
  });

  // ── Publishing (pricing plan + payment) ── also used for changing plan on
  // an already-published event, see the "Change plan" section below.
  const plansQuery = useQuery({
    queryKey: ["event-plans"],
    queryFn: async () => {
      const { plans } = await eventPlansApi.list();
      return plans;
    },
    enabled: !!ev,
  });

  const [selectedPlan, setSelectedPlan] = useState<string | null>(null);
  const [showChangePlan, setShowChangePlan] = useState(false);
  // Only relevant once an event that already has a plan (ev.plan set) gets
  // unpublished — gates showing PlanPaymentPanel behind one explicit click
  // rather than auto-firing EventPlanPaymentsController#create the instant
  // this section renders (PlanPaymentPanel starts its own mutation on
  // mount). Reset on every fresh unpublish so re-publishing always requires
  // that click again, rather than a stale `true` from an earlier
  // unpublish/republish cycle in the same page session skipping it.
  const [confirmRepublish, setConfirmRepublish] = useState(false);

  const unpublishEvent = useMutation({
    mutationFn: () => eventsApi.unpublish(eventId),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["event", eventId] });
      setConfirmRepublish(false);
      toast.success(t("manageEvent.toastEventUnpublished"));
    },
    onError: (e: any) => toast.error(e.message),
  });

  // Closing is separate from unpublishing on purpose: unpublish hides the
  // event from everyone, including the people already registered who still
  // need the page for the date, the venue and later their results. Closing
  // leaves all of that visible and only stops new sign-ups.
  const closeRegistration = useMutation({
    mutationFn: () => eventsApi.closeRegistration(eventId),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["event", eventId] });
      toast.success(t("manageEvent.toastRegistrationClosed"));
    },
    onError: (e: any) => toast.error(e.message),
  });

  const reopenRegistration = useMutation({
    mutationFn: () => eventsApi.reopenRegistration(eventId),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["event", eventId] });
      toast.success(t("manageEvent.toastRegistrationReopened"));
    },
    onError: (e: any) => toast.error(e.message),
  });

  // `participants` is now *one page*, not everyone. Anything that needs a
  // total must read `summary` — a .length here would silently report 25.
  const participants = participantsQuery.data?.registrations ?? [];
  const pageMeta = participantsQuery.data?.meta;
  const waitlist = waitlistQuery.data ?? [];

  const summary = summaryQuery.data;
  const totalParticipants = summary?.total ?? 0;
  const paidCount = summary?.paid ?? 0;
  const revenue = summary?.revenue_cents ?? 0;
  const checkedInCount = summary?.checked_in ?? 0;

  // Search moved server-side with pagination — filtering an array that only
  // holds the current page would "find" nobody past row 25.
  const filteredForCheckIn = participants;

  const activeBrandColor = brandColor ?? ev?.brand_color ?? "#6366f1";

  // The most people who could register across all of this event's types
  // combined — a plan's capacity has to cover at least this many, or
  // publishing under it would be rejected server-side. Types with no
  // capacity of their own (unlimited) don't add anything here.
  const combinedTypeCapacity = ev?.event_types?.reduce((sum, t) => sum + (t.capacity ?? 0), 0) ?? 0;

  // ── Role-aware chrome (Ticket G) ──
  //
  // Mirrors the backend's EventAuthorization::CAPABILITIES matrix, keyed off
  // `ev.role` (set by Api::V1::EventsController#show — see api-client.ts's
  // ApiEvent.role doc comment). Purely a UI affordance, same caveat as
  // PaidEventGate: hiding a tab or button here doesn't grant or deny
  // anything — every mutation below is re-checked server-side regardless of
  // what this object says. A null/undefined role (a stranger with no
  // relationship to the event at all) sees nothing gated here, which simply
  // never happens in normal use — this page is only ever reached via the
  // owner's own dashboard or an accepted invitation's `my_events` listing.
  const role = ev?.role ?? null;
  // event-freeze-and-terms-tickets.md's Ticket E — mirrors the backend's
  // suspension lockdown (EventAuthorization::SUSPENDED_ALLOWED_CAPABILITIES): every
  // mutating capability below is additionally gated on !isSuspended, same as
  // the server does regardless of role, including the owner. Read
  // capabilities (viewSurveyResponses/viewActivity/viewMembers) are
  // deliberately left untouched — the point of a suspension is that the owner
  // can still see the event and why it was suspended, just not change anything.
  // Every mutation is re-checked server-side anyway (same caveat as the rest
  // of this object), so a stale `ev` that hasn't refetched since a suspension
  // would just get a 403/404 from the API rather than actually doing damage.
  const isSuspended = !!ev?.suspended;
  const can = {
    updateEvent: (role === "owner" || role === "manager") && !isSuspended,
    manageResults: (role === "owner" || role === "manager") && !isSuspended,
    checkIn: (role === "owner" || role === "manager" || role === "check_in") && !isSuspended,
    exportParticipants: (role === "owner" || role === "manager") && !isSuspended,
    updateRegistration: (role === "owner" || role === "manager") && !isSuspended,
    removeParticipant: (role === "owner" || role === "manager") && !isSuspended,
    viewSurveyResponses: role === "owner" || role === "manager" || role === "viewer",
    viewActivity: role === "owner" || role === "manager" || role === "viewer",
    managePlan: role === "owner" && !isSuspended,
    unpublishEvent: role === "owner" && !isSuspended,
    deleteEvent: role === "owner" && !isSuspended,
    // Not a direct CAPABILITIES mirror: the Members tab's own read endpoint
    // (EventMembersController#index) permits every role incl. Check-in, but
    // Check-in's whole point is a narrow, single-purpose surface — see this
    // ticket's acceptance criteria ("Check-in member shows the Check-in and
    // Participants tabs and nothing else"). manage_members itself stays
    // owner-only either way (enforced inside MembersTab via `canManage`,
    // which also needs !isSuspended — see where MembersTab is rendered below).
    viewMembers: role === "owner" || role === "manager" || role === "viewer",
  };

  const hasSurvey = !!ev?.survey_id;
  // Nine flat tabs didn't fit: at ~95px per column the labels were unreadable,
  // and the grid was sized from a key count that didn't match the number of
  // triggers rendered, so the last one wrapped onto its own row. Both problems
  // go away by grouping — four things you reach for during an event stay on
  // the bar, configuration collapses into Setup, and the rarely-opened
  // read-only views move behind an overflow menu.
  //
  // Each panel keeps its own permission, and a *group* only appears when at
  // least one panel inside it does. Otherwise a Viewer could land on a Setup
  // tab containing nothing.
  const panelVisibility = {
    participants: true,
    checkin: can.checkIn,
    results: can.manageResults,
    branding: can.updateEvent,
    registration: can.updateEvent,
    certificate: can.updateEvent,
    responses: hasSurvey && can.viewSurveyResponses,
    activity: can.viewActivity,
    members: can.viewMembers,
  };

  // Panels reachable through the Setup tab's own second-level nav.
  const setupPanels = (["branding", "registration", "certificate"] as const).filter(
    (k) => panelVisibility[k],
  );
  // Read-only views behind "More" — opened occasionally, never mid-event.
  const overflowPanels = (["responses", "activity", "members"] as const).filter(
    (k) => panelVisibility[k],
  );

  const primaryTabs = [
    { value: "participants", icon: Users, label: t("manageEvent.tabParticipants") },
    { value: "checkin", icon: ScanLine, label: t("manageEvent.tabCheckIn") },
    { value: "results", icon: Trophy, label: t("manageEvent.tabResults") },
  ].filter((tabItem) => panelVisibility[tabItem.value as keyof typeof panelVisibility]);

  const overflowLabels: Record<string, string> = {
    responses: t("manageEvent.tabResponses"),
    activity: t("manageEvent.tabActivity"),
    members: t("manageEvent.tabMembers"),
  };

  const [setupTab, setSetupTab] = useState<string>("branding");
  // Whichever overflow panel is open, so the More button can show it as
  // selected — without this, choosing Activity Logs leaves no tab looking
  // active and the bar reads as though nothing is open.
  const activeOverflow = overflowPanels.find((k) => k === tab);

  return (
    <div className="min-h-screen bg-background">
      <SiteHeader />
      <main className="mx-auto max-w-4xl px-5 py-10">
        <Button asChild variant="ghost" size="sm" className="mb-4">
          <Link to="/dashboard">
            <ArrowLeft className="h-4 w-4" /> {t("manageEvent.backToDashboard")}
          </Link>
        </Button>

        {eventQuery.isLoading && <p className="text-muted-foreground">{t("common.loading")}</p>}
        {eventQuery.isError && (
          <div className="mt-6 rounded-2xl border border-destructive/30 bg-destructive/5 p-6 text-center">
            <p className="font-medium text-destructive">{t("manageEvent.loadError")}</p>
            <p className="mt-1 text-sm text-muted-foreground">
              {(eventQuery.error as any)?.message ?? t("manageEvent.loadErrorGeneric")}
            </p>
            <Button
              variant="outline"
              size="sm"
              className="mt-4"
              onClick={() => eventQuery.refetch()}
            >
              {t("common.tryAgain")}
            </Button>
          </div>
        )}
        {ev && (
          <>
            {/* Header */}
            <div className="flex flex-wrap items-start justify-between gap-4">
              <div>
                <div className="flex items-center gap-2">
                  <Badge variant="secondary">{categoryLabel(ev.category)}</Badge>
                  {!ev.is_published && <Badge variant="outline">{t("common.draft")}</Badge>}
                  {ev.suspended && (
                    <Badge variant="destructive">{t("manageEvent.suspendedBadge")}</Badge>
                  )}
                  <Badge variant="outline">{formatPrice(ev.price_cents, ev.currency)}</Badge>
                </div>
                <h1 className="mt-2 font-display text-3xl font-bold">{ev.title}</h1>
                <p className="mt-2 flex items-center gap-1.5 text-sm text-muted-foreground">
                  <CalendarDays className="h-4 w-4" /> {formatDateTime(ev.start_at)}
                </p>
                {ev.location && (
                  <p className="mt-1 flex items-center gap-1.5 text-sm text-muted-foreground">
                    <MapPin className="h-4 w-4" /> {ev.location}
                    {ev.latitude != null && ev.longitude != null && (
                      <a
                        href={googleMapsViewUrl(ev.latitude, ev.longitude)}
                        target="_blank"
                        rel="noreferrer"
                        className="inline-flex items-center gap-1 underline underline-offset-2 hover:text-foreground"
                      >
                        {t("eventDetail.viewOnMap")} <ExternalLink className="h-3 w-3" />
                      </a>
                    )}
                  </p>
                )}
                {ev.route_map_url && (
                  <p className="mt-1 flex items-center gap-1.5 text-sm text-muted-foreground">
                    <Milestone className="h-4 w-4" />
                    <a
                      href={ev.route_map_url}
                      target="_blank"
                      rel="noreferrer"
                      className="inline-flex items-center gap-1 underline underline-offset-2 hover:text-foreground"
                    >
                      {t("eventDetail.viewRoute")} <ExternalLink className="h-3 w-3" />
                    </a>
                  </p>
                )}
              </div>
              <div className="flex gap-2">
                <Button variant="outline" size="sm" onClick={() => downloadICS(ev)}>
                  <Download className="h-4 w-4" /> .ics
                </Button>
                {ev.is_published && can.unpublishEvent && (
                  <Button
                    variant="outline"
                    size="sm"
                    onClick={() => unpublishEvent.mutate()}
                    disabled={unpublishEvent.isPending}
                  >
                    {unpublishEvent.isPending ? (
                      <Loader2 className="h-4 w-4 animate-spin" />
                    ) : (
                      <EyeOff className="h-4 w-4" />
                    )}
                    {t("manageEvent.unpublish")}
                  </Button>
                )}
                {can.deleteEvent && (
                  <AlertDialog>
                    <AlertDialogTrigger asChild>
                      <Button variant="outline" size="sm">
                        <Trash2 className="h-4 w-4" /> {t("common.delete")}
                      </Button>
                    </AlertDialogTrigger>
                    <AlertDialogContent>
                      <AlertDialogHeader>
                        <AlertDialogTitle>{t("manageEvent.deleteDialogTitle")}</AlertDialogTitle>
                        <AlertDialogDescription>
                          {t("manageEvent.deleteDialogDesc")}
                        </AlertDialogDescription>
                      </AlertDialogHeader>
                      <AlertDialogFooter>
                        <AlertDialogCancel>{t("common.cancel")}</AlertDialogCancel>
                        <AlertDialogAction onClick={() => deleteEvent.mutate()}>
                          {t("common.delete")}
                        </AlertDialogAction>
                      </AlertDialogFooter>
                    </AlertDialogContent>
                  </AlertDialog>
                )}
              </div>
            </div>

            {/* Publish (pricing plan) — manage_plan is owner-only (plan
                payments charge the owner's own card, see
                EventAuthorization::CAPABILITIES) */}
            {!ev.is_published && can.managePlan && (
              <div className="mt-8 rounded-2xl border border-primary/30 bg-primary/5 p-6">
                <div className="flex items-center gap-2">
                  <Rocket className="h-5 w-5 text-primary" />
                  <h2 className="font-semibold">{t("manageEvent.publishTitle")}</h2>
                </div>

                {ev.plan ? (
                  // Already picked a plan before — this is an unpublish →
                  // republish cycle, not a fresh draft, so don't make the
                  // organizer choose again. Deliberately-switching plans is
                  // its own "Change plan" flow (published events only,
                  // below); this just restores the plan already on file.
                  // EventPlanPaymentsController#create republishes for free
                  // with no new charge when the plan matches the event's
                  // existing one.
                  <>
                    <p className="mt-1 text-sm text-muted-foreground">
                      {t("manageEvent.republishDesc", { plan: ev.plan.replace("_", " ") })}
                    </p>
                    {combinedTypeCapacity > 0 && (
                      <p className="mt-1 text-sm text-muted-foreground">
                        {t("manageEvent.combinedCapacityPrefix")}{" "}
                        <strong>{combinedTypeCapacity.toLocaleString()}</strong>{" "}
                        {t("manageEvent.combinedCapacitySuffix")}
                      </p>
                    )}

                    {confirmRepublish ? (
                      <div className="mt-5 rounded-xl border border-border bg-card p-5">
                        <p className="text-sm font-medium capitalize">
                          {ev.plan.replace("_", " ")} {t("manageEvent.planSuffix")}
                        </p>
                        <PlanPaymentPanel
                          eventId={eventId}
                          plan={ev.plan}
                          brandColor={activeBrandColor}
                          onPublished={() => setConfirmRepublish(false)}
                        />
                      </div>
                    ) : (
                      <Button className="mt-5 gap-2" onClick={() => setConfirmRepublish(true)}>
                        <Rocket className="h-4 w-4" /> {t("manageEvent.republishButton")}
                      </Button>
                    )}
                  </>
                ) : (
                  <>
                    <p className="mt-1 text-sm text-muted-foreground">
                      {t("manageEvent.publishDesc")}
                    </p>
                    {combinedTypeCapacity > 0 && (
                      <p className="mt-1 text-sm text-muted-foreground">
                        {t("manageEvent.combinedCapacityPrefix")}{" "}
                        <strong>{combinedTypeCapacity.toLocaleString()}</strong>{" "}
                        {t("manageEvent.combinedCapacitySuffix")}
                      </p>
                    )}

                    {selectedPlan ? (
                      <div className="mt-5 rounded-xl border border-border bg-card p-5">
                        <div className="flex items-center justify-between">
                          <p className="text-sm font-medium capitalize">
                            {selectedPlan.replace("_", " ")} {t("manageEvent.planSuffix")}
                          </p>
                          <Button variant="ghost" size="sm" onClick={() => setSelectedPlan(null)}>
                            {t("manageEvent.changePlan")}
                          </Button>
                        </div>
                        <PlanPaymentPanel
                          eventId={eventId}
                          plan={selectedPlan}
                          brandColor={activeBrandColor}
                          onPublished={() => setSelectedPlan(null)}
                        />
                      </div>
                    ) : (
                      <div className="mt-5 grid gap-3 sm:grid-cols-2 lg:grid-cols-5">
                        {plansQuery.isLoading && (
                          <p className="text-sm text-muted-foreground">
                            {t("manageEvent.loadingPlans")}
                          </p>
                        )}
                        {plansQuery.data?.map((plan) => {
                          const tooSmall = plan.capacity < combinedTypeCapacity;
                          return (
                            <button
                              key={plan.id}
                              type="button"
                              disabled={tooSmall}
                              onClick={() => setSelectedPlan(plan.id)}
                              className={cn(
                                "rounded-xl border border-border bg-card p-4 text-left transition-colors",
                                tooSmall ? "cursor-not-allowed opacity-50" : "hover:border-primary",
                              )}
                            >
                              <p className="text-sm font-semibold">{plan.label}</p>
                              <p className="mt-1 text-lg font-bold">
                                {plan.price_cents === 0
                                  ? t("common.free")
                                  : formatPrice(plan.price_cents, "usd")}
                              </p>
                              <p className="mt-1 text-xs text-muted-foreground">
                                {t("manageEvent.upToPeople", { count: plan.capacity })}
                              </p>
                              {tooSmall && (
                                <p className="mt-1 text-xs text-destructive">
                                  {t("manageEvent.tooSmall")}
                                </p>
                              )}
                            </button>
                          );
                        })}
                      </div>
                    )}
                  </>
                )}
              </div>
            )}

            {/* Change plan (published events only) — owner-only, same
                manage_plan reasoning as the Publish section above */}
            {ev.is_published && can.managePlan && (
              <div className="mt-8 rounded-2xl border border-border bg-card p-6">
                <div className="flex flex-wrap items-center justify-between gap-4">
                  <div>
                    <p className="text-sm font-semibold">{t("manageEvent.currentPlanTitle")}</p>
                    <p className="mt-1 text-sm text-muted-foreground">
                      {t("manageEvent.currentPlanDesc", {
                        plan: ev.plan ? ev.plan.replace("_", " ") : "—",
                        capacity: ev.capacity ?? "—",
                      })}
                    </p>
                  </div>
                  {!selectedPlan && (
                    <Button
                      variant="outline"
                      size="sm"
                      onClick={() => setShowChangePlan((v) => !v)}
                    >
                      {showChangePlan ? t("common.cancel") : t("manageEvent.changePlan")}
                    </Button>
                  )}
                </div>

                {showChangePlan &&
                  (selectedPlan ? (
                    <div className="mt-5 rounded-xl border border-border bg-muted/30 p-5">
                      <div className="flex items-center justify-between">
                        <p className="text-sm font-medium capitalize">
                          {selectedPlan.replace("_", " ")} {t("manageEvent.planSuffix")}
                        </p>
                        <Button variant="ghost" size="sm" onClick={() => setSelectedPlan(null)}>
                          {t("manageEvent.changePlan")}
                        </Button>
                      </div>
                      <PlanPaymentPanel
                        eventId={eventId}
                        plan={selectedPlan}
                        brandColor={activeBrandColor}
                        mode="change"
                        onPublished={() => {
                          setSelectedPlan(null);
                          setShowChangePlan(false);
                        }}
                      />
                    </div>
                  ) : (
                    <>
                      <p className="mt-3 text-xs text-muted-foreground">
                        {t("manageEvent.changePlanDesc")}
                      </p>
                      <div className="mt-4 grid gap-3 sm:grid-cols-2 lg:grid-cols-5">
                        {plansQuery.isLoading && (
                          <p className="text-sm text-muted-foreground">
                            {t("manageEvent.loadingPlans")}
                          </p>
                        )}
                        {plansQuery.data?.map((plan) => {
                          const isCurrent = plan.id === ev.plan;
                          const tooSmallForTypes = plan.capacity < combinedTypeCapacity;
                          const tooSmallForRegistered = plan.capacity < totalParticipants;
                          const disabled = isCurrent || tooSmallForTypes || tooSmallForRegistered;
                          return (
                            <button
                              key={plan.id}
                              type="button"
                              disabled={disabled}
                              onClick={() => setSelectedPlan(plan.id)}
                              className={cn(
                                "rounded-xl border border-border bg-card p-4 text-left transition-colors",
                                disabled ? "cursor-not-allowed opacity-50" : "hover:border-primary",
                              )}
                            >
                              <div className="flex items-center justify-between gap-2">
                                <p className="text-sm font-semibold">{plan.label}</p>
                                {isCurrent && (
                                  <Badge variant="secondary" className="text-[10px]">
                                    {t("manageEvent.currentPlanBadge")}
                                  </Badge>
                                )}
                              </div>
                              <p className="mt-1 text-lg font-bold">
                                {plan.price_cents === 0
                                  ? t("common.free")
                                  : formatPrice(plan.price_cents, "usd")}
                              </p>
                              <p className="mt-1 text-xs text-muted-foreground">
                                {t("manageEvent.upToPeople", { count: plan.capacity })}
                              </p>
                              {!isCurrent && (tooSmallForTypes || tooSmallForRegistered) && (
                                <p className="mt-1 text-xs text-destructive">
                                  {tooSmallForRegistered
                                    ? t("manageEvent.tooSmallRegistered")
                                    : t("manageEvent.tooSmall")}
                                </p>
                              )}
                            </button>
                          );
                        })}
                      </div>
                    </>
                  ))}
              </div>
            )}

            {/* Stats */}
            <div className="mt-8 grid gap-4 sm:grid-cols-2 lg:grid-cols-5">
              <Stat
                icon={Users}
                label={t("manageEvent.statParticipants")}
                value={`${totalParticipants}${ev.capacity ? ` / ${ev.capacity}` : ""}`}
              />
              <Stat
                icon={Check}
                label={t("manageEvent.statPaid")}
                value={ev.price_cents === 0 ? "—" : `${paidCount} / ${totalParticipants}`}
              />
              <Stat
                icon={DollarSign}
                label={t("manageEvent.statRevenue")}
                value={formatPrice(revenue, ev.currency)}
              />
              <Stat
                icon={Hourglass}
                label={t("manageEvent.statWaitlist")}
                value={`${waitlist.length}`}
              />
              <Stat
                icon={ScanLine}
                label={t("manageEvent.statCheckedIn")}
                value={`${checkedInCount} / ${totalParticipants}`}
              />
            </div>

            {/* Waitlist */}
            {waitlist.length > 0 && (
              <div className="mt-6 rounded-2xl border border-border bg-card p-5">
                <p className="text-sm font-semibold">{t("manageEvent.waitlistSectionTitle")}</p>
                <p className="mt-0.5 text-xs text-muted-foreground">
                  {t("manageEvent.waitlistSectionDesc")}
                </p>
                <div className="mt-4 divide-y divide-border">
                  {waitlist.map((entry) => (
                    <div
                      key={entry.id}
                      className="flex flex-wrap items-center justify-between gap-2 py-2.5 first:pt-0 last:pb-0"
                    >
                      <div className="flex items-center gap-3 min-w-0">
                        <Badge variant="outline" className="shrink-0 font-mono text-xs">
                          {t("manageEvent.waitlistPositionLabel", { position: entry.position })}
                        </Badge>
                        <p className="truncate text-sm font-medium">
                          {entry.profile?.display_name ?? entry.email}
                        </p>
                      </div>
                      <p className="text-xs text-muted-foreground">
                        {t("manageEvent.waitlistJoinedOn", { date: formatDate(entry.created_at) })}
                      </p>
                    </div>
                  ))}
                </div>
              </div>
            )}

            {/* Per-type breakdown */}
            {ev.event_types?.length > 0 && (
              <div className="mt-6 rounded-2xl border border-border bg-card p-5">
                <p className="text-sm font-semibold mb-3">{t("manageEvent.byType")}</p>
                <div className="space-y-2">
                  {ev.event_types.map((et) => {
                    // From the summary, not the loaded page: this block sits
                    // above the tabs and is always on screen, so counting the
                    // current page would show "3 of 25" for an event with
                    // three thousand people in it.
                    const count = summary?.by_event_type?.[et.id] ?? 0;
                    const pct = totalParticipants
                      ? Math.round((count / totalParticipants) * 100)
                      : 0;
                    return (
                      <div key={et.id} className="flex items-center gap-3">
                        <span className="w-32 truncate text-sm">{et.name}</span>
                        <div className="flex-1 h-2 rounded-full bg-muted overflow-hidden">
                          <div
                            className="h-full rounded-full transition-all"
                            style={{ width: `${pct}%`, backgroundColor: activeBrandColor }}
                          />
                        </div>
                        <span className="w-16 text-right text-sm text-muted-foreground">
                          {count}
                          {et.capacity ? ` / ${et.capacity}` : ""}
                        </span>
                      </div>
                    );
                  })}
                </div>
              </div>
            )}

            {/* Suspended banner — see event-freeze-and-terms-tickets.md's Ticket
                E. Persistent (not dismissable): the point of a suspension is
                that it isn't a one-time notice, it's the current state of
                the event, for as long as it stays suspended. */}
            {ev.suspended && (
              <div className="mt-6 flex items-start gap-3 rounded-2xl border border-destructive/30 bg-destructive/5 p-4">
                <Ban className="mt-0.5 h-5 w-5 shrink-0 text-destructive" />
                <div>
                  <p className="font-medium text-destructive">
                    {t("manageEvent.suspendedBannerTitle")}
                  </p>
                  <p className="mt-1 text-sm text-muted-foreground">
                    {t("manageEvent.suspendedBannerDesc")}
                  </p>
                  {ev.suspension_reason && (
                    <p className="mt-2 text-sm">
                      <span className="font-medium">{t("manageEvent.suspendedBannerReason")}</span>{" "}
                      {ev.suspension_reason}
                    </p>
                  )}
                </div>
              </div>
            )}

            {/* Tabs */}
            <Tabs value={tab} onValueChange={setTab} className="mt-10">
              {/* Auto-width triggers in a flex row, not a fixed grid: the grid
                  needed a hardcoded column count per tab total, which is what
                  silently mis-sized itself when a tab was added. */}
              <div className="flex flex-wrap items-center gap-2">
                <TabsList className="h-auto flex-wrap justify-start">
                  {primaryTabs.map(({ value, icon: Icon, label }) => (
                    <TabsTrigger key={value} value={value}>
                      <Icon className="h-4 w-4 mr-1.5" /> {label}
                    </TabsTrigger>
                  ))}
                  {setupPanels.length > 0 && (
                    <TabsTrigger value="setup">
                      <Settings className="h-4 w-4 mr-1.5" /> {t("manageEvent.tabSetup")}
                    </TabsTrigger>
                  )}
                </TabsList>

                {overflowPanels.length > 0 && (
                  <DropdownMenu>
                    <DropdownMenuTrigger asChild>
                      {/* Deliberately outside TabsList: a non-trigger child
                          would break Radix's roving focus across the tabs. */}
                      <Button
                        variant={activeOverflow ? "secondary" : "ghost"}
                        size="sm"
                        className="h-9"
                      >
                        {activeOverflow ? overflowLabels[activeOverflow] : t("manageEvent.tabMore")}
                        <ChevronDown className="h-4 w-4 ml-1" />
                      </Button>
                    </DropdownMenuTrigger>
                    <DropdownMenuContent align="start">
                      {overflowPanels.map((key) => (
                        <DropdownMenuItem key={key} onSelect={() => setTab(key)}>
                          {overflowLabels[key]}
                        </DropdownMenuItem>
                      ))}
                    </DropdownMenuContent>
                  </DropdownMenu>
                )}
              </div>

              {/* ── Participants ── */}
              <TabsContent value="participants" className="mt-6">
                {can.exportParticipants && (
                  <div className="mb-3 flex justify-end">
                    <Button
                      variant="outline"
                      size="sm"
                      onClick={handleExportCsv}
                      disabled={exportingCsv || totalParticipants === 0}
                    >
                      {exportingCsv ? (
                        <Loader2 className="h-4 w-4 animate-spin" />
                      ) : (
                        <Download className="h-4 w-4" />
                      )}
                      {t("manageEvent.exportCsv")}
                    </Button>
                  </div>
                )}
                <div className="mb-3 flex justify-end">
                  <div className="relative w-full max-w-[260px]">
                    <Search className="pointer-events-none absolute left-2.5 top-1/2 h-3.5 w-3.5 -translate-y-1/2 text-muted-foreground" />
                    <Input
                      value={listSearch}
                      onChange={(e) => setListSearch(e.target.value)}
                      placeholder={t("manageEvent.searchParticipants")}
                      className="pl-8"
                    />
                  </div>
                </div>
                <div className="overflow-hidden rounded-2xl border border-border">
                  {participantsQuery.isLoading && (
                    <p className="p-5 text-sm text-muted-foreground">{t("common.loading")}</p>
                  )}
                  {!participantsQuery.isLoading && participants.length === 0 && (
                    <p className="p-8 text-center text-sm text-muted-foreground">
                      {/* Distinguishes "nobody has registered" from "your
                          search matched nobody" — the same empty table for
                          both leaves an organizer wondering if the data
                          vanished. */}
                      {debouncedSearch
                        ? t("manageEvent.noParticipantsMatch", { query: debouncedSearch })
                        : t("manageEvent.noParticipants")}
                    </p>
                  )}
                  {participants.map((p, i) => (
                    <div
                      key={p.id}
                      className={`flex flex-wrap items-center justify-between gap-3 p-4 ${
                        i > 0 ? "border-t border-border" : ""
                      }`}
                    >
                      <div className="min-w-0">
                        <div className="flex flex-wrap items-center gap-2">
                          <p className="font-medium">
                            {p.profile?.display_name ?? t("manageEvent.participantFallback")}
                          </p>
                          {can.updateRegistration ? (
                            <BibNumberField
                              value={p.bib_number}
                              disabled={setBib.isPending}
                              onSave={(bib) => setBib.mutateAsync({ id: p.id, bib })}
                            />
                          ) : (
                            p.bib_number && (
                              <span className="font-mono text-xs text-muted-foreground">
                                {p.bib_number}
                              </span>
                            )
                          )}
                        </div>
                        <p className="text-xs text-muted-foreground">
                          {t("manageEvent.registeredOn", { date: formatDate(p.created_at) })}
                        </p>
                        {p.event_types?.length > 0 && (
                          <div className="flex flex-wrap gap-1 mt-1.5">
                            {p.event_types.map((t) => (
                              <Badge key={t.id} variant="secondary" className="text-xs">
                                {t.name}
                              </Badge>
                            ))}
                          </div>
                        )}
                      </div>
                      <div className="flex items-center gap-2">
                        {ev.price_cents > 0 && (
                          <Badge variant={p.payment_status === "paid" ? "default" : "outline"}>
                            {p.payment_status === "paid"
                              ? t("manageEvent.paidBadge")
                              : t("manageEvent.unpaidBadge")}
                          </Badge>
                        )}
                        {ev.price_cents > 0 &&
                          can.updateRegistration &&
                          (p.payment_status === "paid" ? (
                            <Button
                              variant="ghost"
                              size="sm"
                              onClick={() =>
                                setPayment.mutate({ id: p.id, status: "unpaid", amount: 0 })
                              }
                            >
                              <X className="h-4 w-4" /> {t("manageEvent.markUnpaid")}
                            </Button>
                          ) : (
                            <Button
                              variant="outline"
                              size="sm"
                              onClick={() =>
                                setPayment.mutate({
                                  id: p.id,
                                  status: "paid",
                                  amount: ev.price_cents,
                                })
                              }
                            >
                              <Check className="h-4 w-4" /> {t("manageEvent.markPaid")}
                            </Button>
                          ))}
                        {can.removeParticipant && (
                          <AlertDialog>
                            <AlertDialogTrigger asChild>
                              <Button variant="ghost" size="sm">
                                <Trash2 className="h-4 w-4" />
                              </Button>
                            </AlertDialogTrigger>
                            <AlertDialogContent>
                              <AlertDialogHeader>
                                <AlertDialogTitle>
                                  {t("manageEvent.removeParticipantDialogTitle")}
                                </AlertDialogTitle>
                                <AlertDialogDescription>
                                  {t("manageEvent.removeParticipantDialogDesc", {
                                    name:
                                      p.profile?.display_name ??
                                      t("manageEvent.participantFallback"),
                                  })}
                                </AlertDialogDescription>
                              </AlertDialogHeader>
                              <AlertDialogFooter>
                                <AlertDialogCancel>{t("common.cancel")}</AlertDialogCancel>
                                <AlertDialogAction
                                  disabled={removeParticipant.isPending}
                                  onClick={() => removeParticipant.mutate(p.id)}
                                >
                                  {t("common.remove")}
                                </AlertDialogAction>
                              </AlertDialogFooter>
                            </AlertDialogContent>
                          </AlertDialog>
                        )}
                      </div>
                    </div>
                  ))}
                  {/* Sibling of the row map, not a child of it. It first
                      shipped nested inside each row's event-type badge row,
                      which rendered a pager per participant and — because that
                      block is gated on `p.event_types?.length > 0` — rendered
                      none at all for an event with no types, which is most of
                      them. */}
                  <ListPager
                    meta={pageMeta}
                    busy={participantsQuery.isFetching}
                    onPageChange={setListPage}
                  />
                </div>
              </TabsContent>

              {/* ── Check-in ── */}
              {panelVisibility.checkin && (
                <TabsContent value="checkin" className="mt-6 space-y-6">
                  <CheckInScanner onCheckedIn={invalidateParticipants} />

                  <div className="overflow-hidden rounded-2xl border border-border">
                    <div className="flex flex-wrap items-center justify-between gap-3 border-b border-border bg-muted/40 px-5 py-3">
                      <p className="text-sm font-semibold">
                        {t("checkIn.manualListTitle", {
                          checked: checkedInCount,
                          total: totalParticipants,
                        })}
                      </p>
                      <div className="relative w-full max-w-[220px]">
                        <Search className="pointer-events-none absolute left-2.5 top-1/2 h-3.5 w-3.5 -translate-y-1/2 text-muted-foreground" />
                        <Input
                          value={listSearch}
                          onChange={(e) => setListSearch(e.target.value)}
                          placeholder={t("checkIn.searchPlaceholder")}
                          className="h-8 pl-8 text-sm"
                        />
                      </div>
                    </div>
                    {filteredForCheckIn.length === 0 ? (
                      <p className="p-8 text-center text-sm text-muted-foreground">
                        {t("manageEvent.noParticipants")}
                      </p>
                    ) : (
                      <div className="divide-y divide-border">
                        {filteredForCheckIn.map((p) => (
                          <div
                            key={p.id}
                            className="flex flex-wrap items-center justify-between gap-3 p-4"
                          >
                            <div className="min-w-0">
                              <p className="truncate font-medium">
                                {/* Read-only here. The check-in desk is a
                                    place to find someone by their bib, not to
                                    assign one — and the Check-in role can't
                                    edit registrations anyway. */}
                                {p.bib_number && (
                                  <span className="mr-2 font-mono text-xs text-muted-foreground">
                                    {p.bib_number}
                                  </span>
                                )}
                                {p.profile?.display_name ?? t("manageEvent.participantFallback")}
                              </p>
                              {p.checked_in_at && (
                                <p className="text-xs text-muted-foreground">
                                  {t("checkIn.checkedInAt", { date: formatDate(p.checked_in_at) })}
                                </p>
                              )}
                            </div>
                            {p.checked_in_at ? (
                              <Button
                                variant="ghost"
                                size="sm"
                                disabled={undoCheckIn.isPending}
                                onClick={() => undoCheckIn.mutate(p.id)}
                              >
                                <Undo2 className="h-4 w-4" /> {t("checkIn.undo")}
                              </Button>
                            ) : (
                              <Button
                                variant="outline"
                                size="sm"
                                disabled={checkIn.isPending}
                                onClick={() => checkIn.mutate(p.id)}
                              >
                                <Check className="h-4 w-4" /> {t("checkIn.checkInButton")}
                              </Button>
                            )}
                          </div>
                        ))}
                        {/* The wrapper is `divide-y`, which already draws the
                            rule above this as a non-first child. */}
                        <ListPager
                          meta={pageMeta}
                          busy={participantsQuery.isFetching}
                          onPageChange={setListPage}
                          bordered={false}
                        />
                      </div>
                    )}
                  </div>
                </TabsContent>
              )}

              {/* ── Results ── */}
              {panelVisibility.results && (
                <TabsContent value="results" className="mt-6">
                  <ResultsManager
                    eventId={eventId}
                    participants={participants}
                    onChanged={invalidateParticipants}
                  />
                  {/* ResultsManager renders whatever page it's handed, so the
                      pager lives here rather than inside it — the component
                      stays a dumb list and the paging state has one owner. */}
                  <div className="mt-6 rounded-2xl border border-border">
                    <ListPager
                      meta={pageMeta}
                      busy={participantsQuery.isFetching}
                      onPageChange={setListPage}
                      bordered={false}
                    />
                  </div>
                </TabsContent>
              )}

              {/* ── Setup: branding, registration and certificate ──
                  One outer tab with its own second-level nav. These three are
                  all "configure the event before it runs" and none is opened
                  mid-event, so they cost a top-level slot each for no benefit.
                  Nested Tabs (a separate Radix root) rather than local state,
                  so keyboard and ARIA behaviour matches the outer bar. */}
              {setupPanels.length > 0 && (
                <TabsContent value="setup" className="mt-6">
                  <Tabs value={setupTab} onValueChange={setSetupTab}>
                    {/* Underline, not pills-on-a-tray. Styled from the call site
                        rather than by editing the vendored shadcn Tabs, and
                        deliberately NOT the same look as the parent bar: two
                        identical TabsLists stacked read as two peer menus, with
                        nothing saying one is subordinate. Filled pill = primary,
                        underline = secondary is the conventional pairing. */}
                    <TabsList
                      className={SETUP_TABS_LIST_CLASS}
                      aria-label={t("manageEvent.tabSetup")}
                    >
                      {setupPanels.includes("branding") && (
                        <TabsTrigger value="branding" className={SETUP_TAB_TRIGGER_CLASS}>
                          <Palette className="h-4 w-4 mr-1.5" /> {t("manageEvent.tabBranding")}
                        </TabsTrigger>
                      )}
                      {setupPanels.includes("registration") && (
                        <TabsTrigger value="registration" className={SETUP_TAB_TRIGGER_CLASS}>
                          <Ban className="h-4 w-4 mr-1.5" /> {t("manageEvent.tabRegistration")}
                        </TabsTrigger>
                      )}
                      {setupPanels.includes("certificate") && (
                        <TabsTrigger value="certificate" className={SETUP_TAB_TRIGGER_CLASS}>
                          <Award className="h-4 w-4 mr-1.5" /> {t("manageEvent.tabCertificate")}
                        </TabsTrigger>
                      )}
                    </TabsList>

                    {/* ── QR & Branding ── */}
                    {panelVisibility.branding && (
                      <TabsContent value="branding" className="mt-6 space-y-6">
                        {/* QR code card */}
                        <div className="rounded-2xl border border-border bg-card p-6">
                          <div className="flex items-center gap-2 mb-1">
                            <QrCode className="h-5 w-5 text-muted-foreground" />
                            <h2 className="font-semibold">{t("manageEvent.qrTitle")}</h2>
                          </div>
                          <p className="text-sm text-muted-foreground mb-6">
                            {t("manageEvent.qrDesc")}
                          </p>
                          <EventQRCode eventId={eventId} brandColor={activeBrandColor} />
                        </div>

                        {/* Core details editor — title/date/price/etc. */}
                        <EventDetailsEditor event={ev} registeredCount={totalParticipants} />

                        {/* Branding editor card */}
                        <div className="rounded-2xl border border-border bg-card p-6 space-y-5">
                          <div>
                            <h2 className="font-semibold">{t("manageEvent.brandingTitle")}</h2>
                            <p className="text-sm text-muted-foreground">
                              {t("manageEvent.brandingDesc")}
                            </p>
                          </div>

                          <ImageUpload
                            value={bannerUrl ?? null}
                            onChange={setBannerUrl}
                            variant="banner"
                            label={t("manageEvent.bannerImage")}
                          />

                          <div className="flex flex-wrap gap-6">
                            <ImageUpload
                              value={logoUrl ?? null}
                              onChange={setLogoUrl}
                              variant="logo"
                              label={t("manageEvent.logo")}
                            />

                            <div className="flex-1 space-y-2 min-w-[160px]">
                              <Label>{t("manageEvent.brandColor")}</Label>
                              <div className="flex flex-wrap gap-2">
                                {PRESET_COLORS.map((c) => (
                                  <button
                                    key={c}
                                    type="button"
                                    className="h-7 w-7 rounded-full border-2 transition-transform hover:scale-110"
                                    style={{
                                      backgroundColor: c,
                                      borderColor: activeBrandColor === c ? "white" : "transparent",
                                      outline: activeBrandColor === c ? `2px solid ${c}` : "none",
                                      outlineOffset: "1px",
                                    }}
                                    onClick={() => setBrandColor(c)}
                                    aria-label={c}
                                  />
                                ))}
                                <label
                                  className="flex h-7 w-7 cursor-pointer items-center justify-center rounded-full border-2 border-dashed border-border bg-muted text-xs text-muted-foreground hover:border-primary"
                                  title={t("manageEvent.customColor")}
                                >
                                  <input
                                    type="color"
                                    value={activeBrandColor}
                                    onChange={(e) => setBrandColor(e.target.value)}
                                    className="sr-only"
                                  />
                                  +
                                </label>
                              </div>
                              <div className="flex items-center gap-2 mt-1">
                                <span
                                  className="inline-block h-5 w-5 rounded-full border border-border"
                                  style={{ backgroundColor: activeBrandColor }}
                                />
                                <span className="text-xs text-muted-foreground font-mono">
                                  {activeBrandColor}
                                </span>
                              </div>
                            </div>
                          </div>

                          <Button
                            onClick={() => saveBranding.mutate()}
                            disabled={saveBranding.isPending}
                            variant="hero"
                          >
                            {saveBranding.isPending && <Loader2 className="h-4 w-4 animate-spin" />}
                            {t("manageEvent.saveBranding")}
                          </Button>
                        </div>
                      </TabsContent>
                    )}

                    {/* ── Registration status ── */}
                    {panelVisibility.registration && (
                      <TabsContent value="registration" className="mt-6">
                        <div className="rounded-2xl border border-border bg-card p-6 space-y-5">
                          <div className="flex items-center gap-2">
                            <Ban className="h-5 w-5 text-muted-foreground" />
                            <h2 className="font-semibold">{t("manageEvent.registrationTitle")}</h2>
                          </div>
                          <p className="text-sm text-muted-foreground">
                            {t("manageEvent.registrationDesc")}
                          </p>

                          <div className="flex flex-wrap items-center justify-between gap-4 rounded-xl border border-border bg-muted/40 p-4">
                            <div className="min-w-0">
                              <p className="font-medium">
                                {ev.registration_closed
                                  ? t("manageEvent.registrationIsClosed")
                                  : t("manageEvent.registrationIsOpen")}
                              </p>
                              {ev.registration_closes_at && !ev.registration_closed_at && (
                                <p className="mt-1 text-sm text-muted-foreground">
                                  {t("manageEvent.registrationClosesOn", {
                                    date: formatDateTime(ev.registration_closes_at),
                                  })}
                                </p>
                              )}
                            </div>
                            <Button
                              variant="outline"
                              disabled={closeRegistration.isPending || reopenRegistration.isPending}
                              onClick={() =>
                                ev.registration_closed
                                  ? reopenRegistration.mutate()
                                  : closeRegistration.mutate()
                              }
                            >
                              {(closeRegistration.isPending || reopenRegistration.isPending) && (
                                <Loader2 className="h-4 w-4 animate-spin" />
                              )}
                              {ev.registration_closed
                                ? t("manageEvent.reopenRegistration")
                                : t("manageEvent.closeRegistration")}
                            </Button>
                          </div>

                          <div className="space-y-2">
                            <Label htmlFor="registration-closes-at">
                              {t("manageEvent.registrationDeadlineLabel")}
                            </Label>
                            {/* datetime-local has no timezone, so the browser's local
                        zone is what the organizer means — which is right here,
                        since they're setting a deadline for their own event. */}
                            <Input
                              id="registration-closes-at"
                              type="datetime-local"
                              value={registrationClosesAt}
                              onChange={(e) => setRegistrationClosesAt(e.target.value)}
                            />
                            <p className="text-xs text-muted-foreground">
                              {t("manageEvent.registrationDeadlineHint")}
                            </p>
                            <Button
                              onClick={() => saveRegistrationDeadline.mutate()}
                              disabled={saveRegistrationDeadline.isPending}
                              variant="hero"
                            >
                              {saveRegistrationDeadline.isPending && (
                                <Loader2 className="h-4 w-4 animate-spin" />
                              )}
                              {t("manageEvent.saveDeadline")}
                            </Button>
                          </div>
                        </div>
                      </TabsContent>
                    )}

                    {/* ── Certificate of participation ── */}
                    {panelVisibility.certificate && (
                      <TabsContent value="certificate" className="mt-6">
                        <div className="rounded-2xl border border-border bg-card p-6 space-y-5">
                          <div className="flex items-center gap-2">
                            <Award className="h-5 w-5 text-muted-foreground" />
                            <h2 className="font-semibold">{t("manageEvent.certificateTitle")}</h2>
                          </div>
                          <p className="text-sm text-muted-foreground">
                            {t("manageEvent.certificateDesc")}
                          </p>

                          <CertificateTemplateUpload
                            value={certificateTemplateUrl ?? null}
                            onChange={setCertificateTemplateUrl}
                            eventId={eventId}
                          />

                          <Button
                            onClick={() => saveCertificateTemplate.mutate()}
                            disabled={saveCertificateTemplate.isPending}
                            variant="hero"
                          >
                            {saveCertificateTemplate.isPending && (
                              <Loader2 className="h-4 w-4 animate-spin" />
                            )}
                            {t("manageEvent.saveCertificate")}
                          </Button>
                        </div>
                      </TabsContent>
                    )}
                  </Tabs>
                </TabsContent>
              )}

              {/* ── Survey Responses ── */}
              {panelVisibility.responses && (
                <TabsContent value="responses" className="mt-6">
                  {surveyResponsesQuery.isLoading && (
                    <p className="text-sm text-muted-foreground">
                      {t("manageEvent.responsesLoading")}
                    </p>
                  )}

                  {surveyResponsesQuery.isError && (
                    <p className="text-sm text-destructive">{t("manageEvent.responsesError")}</p>
                  )}

                  {surveyResponsesQuery.data && (
                    <>
                      {/* Survey title + response count */}
                      <div className="mb-6 flex items-center justify-between">
                        <div>
                          <h2 className="font-semibold">
                            {surveyResponsesQuery.data.survey.title}
                          </h2>
                          <p className="text-sm text-muted-foreground">
                            {t("manageEvent.responseCount", {
                              count: surveyResponsesQuery.data.responses.length,
                            })}
                          </p>
                        </div>
                      </div>

                      {surveyResponsesQuery.data.responses.length === 0 ? (
                        <div className="rounded-2xl border border-border p-10 text-center text-sm text-muted-foreground">
                          <MessageSquare className="mx-auto h-8 w-8 mb-3 opacity-30" />
                          {t("manageEvent.noResponsesYet")}
                        </div>
                      ) : (
                        /* Per-question breakdown */
                        <div className="space-y-6">
                          {surveyResponsesQuery.data.survey.questions.map((q) => {
                            const answersForQ = surveyResponsesQuery
                              .data!.responses.map((r) => ({
                                user: r.user,
                                answer: r.answers.find((a) => a.survey_question_id === q.id),
                              }))
                              .filter((row) => row.answer);

                            return (
                              <div
                                key={q.id}
                                className="rounded-2xl border border-border bg-card overflow-hidden"
                              >
                                <div className="border-b border-border bg-muted/40 px-5 py-3">
                                  <p className="font-medium text-sm">{q.question_text}</p>
                                  <p className="text-xs text-muted-foreground capitalize mt-0.5">
                                    {q.question_type.replace("_", " ")}
                                    {q.required && ` · ${t("manageEvent.requiredSuffix")}`}
                                  </p>
                                </div>

                                {answersForQ.length === 0 ? (
                                  <p className="px-5 py-4 text-sm text-muted-foreground">
                                    {t("manageEvent.noAnswersYet")}
                                  </p>
                                ) : (
                                  <div className="divide-y divide-border">
                                    {answersForQ.map(({ user, answer }, i) => (
                                      <div key={i} className="flex items-start gap-4 px-5 py-3">
                                        <div className="min-w-0 flex-1">
                                          <p className="text-xs font-medium text-muted-foreground mb-1">
                                            {user.display_name ?? user.email}
                                          </p>
                                          {answer?.question_type === "text" ? (
                                            <p className="text-sm whitespace-pre-wrap">
                                              {answer.answer_text || (
                                                <span className="italic text-muted-foreground">
                                                  {t("manageEvent.noAnswer")}
                                                </span>
                                              )}
                                            </p>
                                          ) : (
                                            <div className="flex flex-wrap gap-1.5">
                                              {(answer?.answer_options ?? []).length === 0 ? (
                                                <span className="text-sm italic text-muted-foreground">
                                                  {t("manageEvent.noAnswer")}
                                                </span>
                                              ) : (
                                                (answer?.answer_options ?? []).map((optId) => {
                                                  const opt = q.options.find((o) => o.id === optId);
                                                  return (
                                                    <Badge key={optId} variant="secondary">
                                                      {opt?.label ?? optId}
                                                    </Badge>
                                                  );
                                                })
                                              )}
                                            </div>
                                          )}
                                        </div>
                                      </div>
                                    ))}
                                  </div>
                                )}
                              </div>
                            );
                          })}
                        </div>
                      )}
                    </>
                  )}
                </TabsContent>
              )}

              {/* ── Activity ── */}
              {panelVisibility.activity && (
                <TabsContent value="activity" className="mt-6">
                  <div className="rounded-2xl border border-border bg-card">
                    {activityQuery.isLoading && (
                      <p className="p-8 text-center text-sm text-muted-foreground">
                        {t("common.loading")}
                      </p>
                    )}
                    {!activityQuery.isLoading && (activityQuery.data ?? []).length === 0 && (
                      <p className="p-8 text-center text-sm text-muted-foreground">
                        {t("manageEvent.noActivity")}
                      </p>
                    )}
                    {(activityQuery.data ?? []).map((a, i) => (
                      <div
                        key={a.id}
                        className={`flex items-start gap-3 p-4 ${
                          i > 0 ? "border-t border-border" : ""
                        }`}
                      >
                        <span className="mt-0.5 flex h-8 w-8 shrink-0 items-center justify-center rounded-full bg-muted">
                          <ActivityIcon activity={a} />
                        </span>
                        <div className="min-w-0 flex-1">
                          <div className="space-y-0.5 text-sm">
                            {describeEventActivity(a, ev.currency).map((line, idx) => (
                              <p key={idx}>{line}</p>
                            ))}
                          </div>
                          <p className="mt-1 text-xs text-muted-foreground">
                            {t("manageEvent.activityBy", {
                              name: a.actor_name,
                              date: formatDateTime(a.created_at),
                            })}
                          </p>
                        </div>
                      </div>
                    ))}
                  </div>
                </TabsContent>
              )}

              {/* ── Members ── */}
              {panelVisibility.members && (
                <TabsContent value="members" className="mt-6">
                  <MembersTab
                    eventId={eventId}
                    canManage={role === "owner" && !isSuspended}
                    currentUserId={user?.id ?? ""}
                  />
                </TabsContent>
              )}
            </Tabs>
          </>
        )}
      </main>
    </div>
  );
}

function Stat({
  icon: Icon,
  label,
  value,
}: {
  icon: React.ComponentType<{ className?: string }>;
  label: string;
  value: string;
}) {
  return (
    <div className="rounded-2xl border border-border bg-card p-5">
      <span className="flex h-9 w-9 items-center justify-center rounded-lg bg-muted text-secondary">
        <Icon className="h-5 w-5" />
      </span>
      <p className="mt-3 text-2xl font-bold">{value}</p>
      <p className="text-sm text-muted-foreground">{label}</p>
    </div>
  );
}
