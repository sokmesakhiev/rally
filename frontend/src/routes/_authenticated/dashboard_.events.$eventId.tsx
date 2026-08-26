import { createFileRoute, Link, useNavigate } from "@tanstack/react-router";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { useState } from "react";
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
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Label } from "@/components/ui/label";
import { Input } from "@/components/ui/input";
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
    const name = (activity.metadata.participant_name as string | null) || i18n.t("manageEvent.participantFallback");
    return [ i18n.t("manageEvent.activityRemovedParticipant", { name }) ];
  }

  if (activity.action === "invite_member") {
    const email = activity.metadata.email as string;
    const role = memberRoleLabel(activity.metadata.role as string);
    return [ i18n.t("manageEvent.activityInvitedMember", { email, role }) ];
  }

  if (activity.action === "revoke_invitation") {
    const email = activity.metadata.email as string;
    return [ i18n.t("manageEvent.activityRevokedInvitation", { email }) ];
  }

  if (activity.action === "member_joined") {
    const role = memberRoleLabel(activity.metadata.role as string);
    return [ i18n.t("manageEvent.activityMemberJoined", { role }) ];
  }

  if (activity.action === "remove_member") {
    const name =
      (activity.metadata.member_name as string | null) ||
      (activity.metadata.member_email as string | null) ||
      i18n.t("manageEvent.memberFallback");
    return activity.metadata.self_removal
      ? [ i18n.t("manageEvent.activityLeftTeam") ]
      : [ i18n.t("manageEvent.activityRemovedMember", { name }) ];
  }

  if (activity.action === "change_member_role") {
    const name =
      (activity.metadata.member_name as string | null) ||
      (activity.metadata.member_email as string | null) ||
      i18n.t("manageEvent.memberFallback");
    const from = memberRoleLabel(activity.metadata.from as string);
    const to = memberRoleLabel(activity.metadata.to as string);
    return [ i18n.t("manageEvent.activityChangedMemberRole", { name, from, to }) ];
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
  const [certificateTemplateUrl, setCertificateTemplateUrl] = useState<
    string | null | undefined
  >(undefined);

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

  const participantsQuery = useQuery({
    queryKey: ["event-participants", eventId],
    queryFn: () => registrationsApi.forEvent(eventId).then((r) => r.registrations),
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

  const removeParticipant = useMutation({
    mutationFn: (id: string) => registrationsApi.remove(id),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["event-participants", eventId] });
      queryClient.invalidateQueries({ queryKey: ["event-activity", eventId] });
      toast.success(t("manageEvent.toastParticipantRemoved"));
    },
    onError: (e: any) => toast.error(e.message),
  });

  const invalidateParticipants = () =>
    queryClient.invalidateQueries({ queryKey: ["event-participants", eventId] });

  const checkIn = useMutation({
    mutationFn: (id: string) => registrationsApi.checkIn(id),
    onSuccess: (data) => {
      invalidateParticipants();
      if (!data.already_checked_in) toast.success(t("checkIn.checkedInToast", {
        name: data.registration.profile?.display_name || t("checkIn.unnamedParticipant"),
      }));
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

  const [checkInSearch, setCheckInSearch] = useState("");

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

  const participants = participantsQuery.data ?? [];
  const waitlist = waitlistQuery.data ?? [];
  const paidCount = participants.filter((p) => p.payment_status === "paid").length;
  const revenue = participants.reduce((sum, p) => sum + (p.amount_paid_cents ?? 0), 0);
  const checkedInCount = participants.filter((p) => p.checked_in_at).length;
  const filteredForCheckIn = participants.filter((p) =>
    (p.profile?.display_name ?? "").toLowerCase().includes(checkInSearch.trim().toLowerCase()),
  );

  const activeBrandColor = brandColor ?? ev?.brand_color ?? "#6366f1";

  // The most people who could register across all of this event's types
  // combined — a plan's capacity has to cover at least this many, or
  // publishing under it would be rejected server-side. Types with no
  // capacity of their own (unlimited) don't add anything here.
  const combinedTypeCapacity = ev?.event_types?.reduce((sum, t) => sum + (t.capacity ?? 0), 0) ?? 0;

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
                {ev.is_published && (
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
              </div>
            </div>

            {/* Publish (pricing plan) */}
            {!ev.is_published && (
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

            {/* Change plan (published events only) */}
            {ev.is_published && (
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
                          const tooSmallForRegistered = plan.capacity < participants.length;
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
                value={`${participants.length}${ev.capacity ? ` / ${ev.capacity}` : ""}`}
              />
              <Stat
                icon={Check}
                label={t("manageEvent.statPaid")}
                value={ev.price_cents === 0 ? "—" : `${paidCount} / ${participants.length}`}
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
                value={`${checkedInCount} / ${participants.length}`}
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
                    const count = participants.filter((p) =>
                      p.event_types?.some((t) => t.id === et.id),
                    ).length;
                    const pct = participants.length
                      ? Math.round((count / participants.length) * 100)
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

            {/* Tabs */}
            <Tabs defaultValue="branding" className="mt-10">
              <TabsList
                className={`grid w-full ${ev?.survey_id ? "max-w-3xl grid-cols-7" : "max-w-2xl grid-cols-6"}`}
              >
                <TabsTrigger value="branding">
                  <Palette className="h-4 w-4 mr-1.5" /> {t("manageEvent.tabBranding")}
                </TabsTrigger>
                <TabsTrigger value="participants">
                  <Users className="h-4 w-4 mr-1.5" /> {t("manageEvent.tabParticipants")}
                </TabsTrigger>
                <TabsTrigger value="checkin">
                  <ScanLine className="h-4 w-4 mr-1.5" /> {t("manageEvent.tabCheckIn")}
                </TabsTrigger>
                <TabsTrigger value="results">
                  <Trophy className="h-4 w-4 mr-1.5" /> {t("manageEvent.tabResults")}
                </TabsTrigger>
                {ev?.survey_id && (
                  <TabsTrigger value="responses">
                    <ClipboardList className="h-4 w-4 mr-1.5" /> {t("manageEvent.tabResponses")}
                  </TabsTrigger>
                )}
                <TabsTrigger value="certificate">
                  <Award className="h-4 w-4 mr-1.5" /> {t("manageEvent.tabCertificate")}
                </TabsTrigger>
                <TabsTrigger value="activity">
                  <History className="h-4 w-4 mr-1.5" /> {t("manageEvent.tabActivity")}
                </TabsTrigger>
              </TabsList>

              {/* ── Participants ── */}
              <TabsContent value="participants" className="mt-6">
                <div className="mb-3 flex justify-end">
                  <Button
                    variant="outline"
                    size="sm"
                    onClick={handleExportCsv}
                    disabled={exportingCsv || participants.length === 0}
                  >
                    {exportingCsv ? (
                      <Loader2 className="h-4 w-4 animate-spin" />
                    ) : (
                      <Download className="h-4 w-4" />
                    )}
                    {t("manageEvent.exportCsv")}
                  </Button>
                </div>
                <div className="overflow-hidden rounded-2xl border border-border">
                  {participantsQuery.isLoading && (
                    <p className="p-5 text-sm text-muted-foreground">{t("common.loading")}</p>
                  )}
                  {!participantsQuery.isLoading && participants.length === 0 && (
                    <p className="p-8 text-center text-sm text-muted-foreground">
                      {t("manageEvent.noParticipants")}
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
                        <p className="font-medium">
                          {p.profile?.display_name ?? t("manageEvent.participantFallback")}
                        </p>
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
                                  name: p.profile?.display_name ?? t("manageEvent.participantFallback"),
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
                      </div>
                    </div>
                  ))}
                </div>
              </TabsContent>

              {/* ── Check-in ── */}
              <TabsContent value="checkin" className="mt-6 space-y-6">
                <CheckInScanner onCheckedIn={invalidateParticipants} />

                <div className="overflow-hidden rounded-2xl border border-border">
                  <div className="flex flex-wrap items-center justify-between gap-3 border-b border-border bg-muted/40 px-5 py-3">
                    <p className="text-sm font-semibold">
                      {t("checkIn.manualListTitle", {
                        checked: checkedInCount,
                        total: participants.length,
                      })}
                    </p>
                    <div className="relative w-full max-w-[220px]">
                      <Search className="pointer-events-none absolute left-2.5 top-1/2 h-3.5 w-3.5 -translate-y-1/2 text-muted-foreground" />
                      <Input
                        value={checkInSearch}
                        onChange={(e) => setCheckInSearch(e.target.value)}
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
                    </div>
                  )}
                </div>
              </TabsContent>

              {/* ── Results ── */}
              <TabsContent value="results" className="mt-6">
                <ResultsManager
                  eventId={eventId}
                  participants={participants}
                  onChanged={invalidateParticipants}
                />
              </TabsContent>

              {/* ── QR & Branding ── */}
              <TabsContent value="branding" className="mt-6 space-y-6">
                {/* QR code card */}
                <div className="rounded-2xl border border-border bg-card p-6">
                  <div className="flex items-center gap-2 mb-1">
                    <QrCode className="h-5 w-5 text-muted-foreground" />
                    <h2 className="font-semibold">{t("manageEvent.qrTitle")}</h2>
                  </div>
                  <p className="text-sm text-muted-foreground mb-6">{t("manageEvent.qrDesc")}</p>
                  <EventQRCode eventId={eventId} brandColor={activeBrandColor} />
                </div>

                {/* Core details editor — title/date/price/etc. */}
                <EventDetailsEditor event={ev} registeredCount={participants.length} />

                {/* Branding editor card */}
                <div className="rounded-2xl border border-border bg-card p-6 space-y-5">
                  <div>
                    <h2 className="font-semibold">{t("manageEvent.brandingTitle")}</h2>
                    <p className="text-sm text-muted-foreground">{t("manageEvent.brandingDesc")}</p>
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

              {/* ── Certificate of participation ── */}
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

              {/* ── Survey Responses ── */}
              {ev?.survey_id && (
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
