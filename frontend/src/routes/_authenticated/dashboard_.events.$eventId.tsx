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
} from "lucide-react";
import { toast } from "sonner";
import { useTranslation } from "react-i18next";
import {
  eventsApi,
  registrationsApi,
  surveyResponsesApi,
  eventPlansApi,
  type ApiSurveyResponse,
} from "@/lib/api-client";
import { useAuth } from "@/lib/use-auth";
import { SiteHeader } from "@/components/site-header";
import { EventQRCode } from "@/components/event-qr-code";
import { ImageUpload } from "@/components/image-upload";
import { PlanPaymentPanel } from "@/components/plan-payment-panel";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Label } from "@/components/ui/label";
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
} from "@/lib/event-utils";
import { downloadICS } from "@/lib/ics";
import { cn } from "@/lib/utils";

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

  const participantsQuery = useQuery({
    queryKey: ["event-participants", eventId],
    queryFn: () => registrationsApi.forEvent(eventId).then((r) => r.registrations),
  });

  const surveyResponsesQuery = useQuery({
    queryKey: ["survey-responses", eventId],
    enabled: !!ev?.survey_id,
    queryFn: () => surveyResponsesApi.forEvent(eventId),
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
      toast.success(t("manageEvent.toastParticipantRemoved"));
    },
    onError: (e: any) => toast.error(e.message),
  });

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

  const deleteEvent = useMutation({
    mutationFn: () => eventsApi.delete(eventId),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["my-events"] });
      toast.success(t("manageEvent.toastEventDeleted"));
      navigate({ to: "/dashboard" });
    },
    onError: (e: any) => toast.error(e.message),
  });

  // ── Publishing (pricing plan + payment) ──
  const plansQuery = useQuery({
    queryKey: ["event-plans"],
    queryFn: async () => {
      const { plans } = await eventPlansApi.list();
      return plans;
    },
    enabled: !!ev && !ev.is_published,
  });

  const [selectedPlan, setSelectedPlan] = useState<string | null>(null);

  const unpublishEvent = useMutation({
    mutationFn: () => eventsApi.unpublish(eventId),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["event", eventId] });
      toast.success(t("manageEvent.toastEventUnpublished"));
    },
    onError: (e: any) => toast.error(e.message),
  });

  const participants = participantsQuery.data ?? [];
  const paidCount = participants.filter((p) => p.payment_status === "paid").length;
  const revenue = participants.reduce((sum, p) => sum + (p.amount_paid_cents ?? 0), 0);

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
                <p className="mt-1 text-sm text-muted-foreground">
                  {t("manageEvent.publishDesc")}
                  {ev.plan && (
                    <>
                      {" "}
                      {t("manageEvent.previouslyPickedPrefix")}{" "}
                      <strong>{ev.plan.replace("_", " ")}</strong>{" "}
                      {t("manageEvent.previouslyPickedSuffix")}
                    </>
                  )}
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
              </div>
            )}

            {/* Stats */}
            <div className="mt-8 grid gap-4 sm:grid-cols-3">
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
            </div>

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
            <Tabs defaultValue="participants" className="mt-10">
              <TabsList
                className={`grid w-full ${ev?.survey_id ? "max-w-lg grid-cols-3" : "max-w-sm grid-cols-2"}`}
              >
                <TabsTrigger value="participants">
                  <Users className="h-4 w-4 mr-1.5" /> {t("manageEvent.tabParticipants")}
                </TabsTrigger>
                <TabsTrigger value="branding">
                  <Palette className="h-4 w-4 mr-1.5" /> {t("manageEvent.tabBranding")}
                </TabsTrigger>
                {ev?.survey_id && (
                  <TabsTrigger value="responses">
                    <ClipboardList className="h-4 w-4 mr-1.5" /> {t("manageEvent.tabResponses")}
                  </TabsTrigger>
                )}
              </TabsList>

              {/* ── Participants ── */}
              <TabsContent value="participants" className="mt-6">
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
                        <Button
                          variant="ghost"
                          size="sm"
                          onClick={() => removeParticipant.mutate(p.id)}
                        >
                          <Trash2 className="h-4 w-4" />
                        </Button>
                      </div>
                    </div>
                  ))}
                </div>
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
