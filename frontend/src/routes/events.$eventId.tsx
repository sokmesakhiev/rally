import { createFileRoute, Link, useNavigate } from "@tanstack/react-router";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { useState } from "react";
import {
  CalendarDays,
  MapPin,
  Milestone,
  Users,
  ArrowLeft,
  Download,
  ExternalLink,
  Loader2,
  Check,
  QrCode,
  Hourglass,
  Award
} from "lucide-react";
import { toast } from "sonner";
import { useTranslation } from "react-i18next";
import {
  eventsApi,
  registrationsApi,
  waitlistApi,
  resultsApi,
  type ApiRegistrationAnswer,
} from "@/lib/api-client";
import { useAuth } from "@/lib/use-auth";
import { SiteHeader } from "@/components/site-header";
import { EventQRCode } from "@/components/event-qr-code";
import { RegistrationTicketQR } from "@/components/registration-ticket-qr";
import { SurveyForm } from "@/components/survey-form";
import { EventTypeSelector } from "@/components/event-type-selector";
import { PaymentPanel } from "@/components/payment-panel";
import { ResultsLeaderboard } from "@/components/results-leaderboard";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  formatDateTime,
  formatPrice,
  formatFinishTime,
  categoryLabel,
  googleMapsViewUrl,
} from "@/lib/event-utils";
import { downloadICS } from "@/lib/ics";

export const Route = createFileRoute("/events/$eventId")({
  head: () => ({ meta: [{ title: "Event — Rally" }] }),
  component: EventDetail,
});

// Registration steps:
//   idle → (guest, if not signed in) → (types if event has types) → (survey if event has survey) → done
type RegStep = "idle" | "guest" | "types" | "survey";

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

function EventDetail() {
  const { eventId } = Route.useParams();
  const { t } = useTranslation();
  const { user, loading, refresh } = useAuth();
  const navigate = useNavigate();
  const queryClient = useQueryClient();

  const [regStep, setRegStep] = useState<RegStep>("idle");
  const [selectedTypeIds, setSelectedTypeIds] = useState<string[]>([]);
  const [guestName, setGuestName] = useState("");
  const [guestEmail, setGuestEmail] = useState("");
  const guestValid = guestName.trim().length > 0 && EMAIL_RE.test(guestEmail.trim());

  // Only actually sent to the backend when there's no signed-in user — see
  // registrationsApi.create.
  function guestPayload() {
    return user ? undefined : { name: guestName.trim(), email: guestEmail.trim() };
  }

  const eventQuery = useQuery({
    queryKey: ["public-event", eventId],
    queryFn: async () => {
      const { event } = await eventsApi.get(eventId);
      return event;
    },
  });

  const regQuery = useQuery({
    queryKey: ["my-reg", eventId, user?.id],
    enabled: !!user,
    queryFn: () => registrationsApi.myRegistrationForEvent(eventId),
  });

  const waitlistQuery = useQuery({
    queryKey: ["my-waitlist", eventId, user?.id],
    enabled: !!user,
    queryFn: () => waitlistApi.myEntryForEvent(eventId),
  });

  // Public — no auth required. Empty groups (nothing recorded yet, which
  // includes every non-race "gathering" event by design) mean
  // ResultsLeaderboard renders nothing, so no conditional fetch needed.
  const leaderboardQuery = useQuery({
    queryKey: ["event-results", eventId],
    queryFn: () => resultsApi.leaderboard(eventId).then((r) => r.groups),
  });

  const [waitlistPendingTypeId, setWaitlistPendingTypeId] = useState<string | null>(null);

  const joinWaitlist = useMutation({
    mutationFn: (opts?: { eventTypeIds?: string[] }) => waitlistApi.join(eventId, opts),
    onSuccess: () => {
      setWaitlistPendingTypeId(null);
      queryClient.invalidateQueries({ queryKey: ["my-waitlist", eventId] });
      toast.success(t("eventDetail.toastJoinedWaitlist"));
    },
    onError: (e: any) => {
      setWaitlistPendingTypeId(null);
      toast.error(e.message ?? t("eventDetail.toastJoinWaitlistError"));
    },
  });

  const leaveWaitlist = useMutation({
    mutationFn: (id: string) => waitlistApi.leave(id),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["my-waitlist", eventId] });
      toast.success(t("eventDetail.toastLeftWaitlist"));
    },
    onError: (e: any) => toast.error(e.message ?? t("eventDetail.toastLeaveWaitlistError")),
  });

  const register = useMutation({
    mutationFn: (opts?: {
      answers?: ApiRegistrationAnswer[];
      eventTypeIds?: string[];
      guest?: { name: string; email: string };
    }) => registrationsApi.create(eventId, opts),
    onSuccess: async (res) => {
      setRegStep("idle");
      setSelectedTypeIds([]);
      // A guest registration silently signs the visitor in (see
      // registrationsApi.create) — pick up the new user in auth context so
      // the rest of this page (payment, "you're registered") renders as
      // signed-in immediately instead of after a manual refresh.
      if (res.auth) await refresh();
      queryClient.invalidateQueries({ queryKey: ["my-reg", eventId] });
      queryClient.invalidateQueries({ queryKey: ["public-event", eventId] });
      queryClient.invalidateQueries({ queryKey: ["my-registrations"] });

      if (res.registration.payment_status === "unpaid") {
        toast.success(t("eventDetail.toastUnpaid"));
      } else {
        toast.success(t("eventDetail.toastPaid"));
        if (ev) downloadICS(ev);
      }
    },
    onError: (e: any) => {
      if (e.code === "full") {
        // The event (or the type they picked) filled up between page load
        // and submit — offer the waitlist right in the toast instead of
        // just failing, and refresh capacity so the UI (disabled types,
        // "Event full" state) reflects reality instead of a stale button
        // they could retry against.
        queryClient.invalidateQueries({ queryKey: ["public-event", eventId] });
        toast.error(e.message ?? t("eventDetail.toastRegisterError"), {
          action: {
            label: t("eventDetail.joinWaitlistToastAction"),
            onClick: () => joinWaitlist.mutate({ eventTypeIds: selectedTypeIds }),
          },
        });
      } else if (e.code === "email_registered") {
        // The email they typed on the guest form already has an account —
        // bounce back to that step so they can see the note and switch to
        // signing in instead of just seeing a generic failure toast.
        setRegStep("guest");
        toast.error(e.message ?? t("eventDetail.guestEmailTaken"), {
          action: {
            label: t("eventDetail.signInInstead"),
            onClick: () => navigate({ to: "/auth" }),
          },
        });
      } else {
        toast.error(e.message ?? t("eventDetail.toastRegisterError"));
      }
    },
  });

  const ev = eventQuery.data;
  const hasTypes = !!ev?.event_types?.length;
  const hasSurvey = !!ev?.survey?.questions?.length;
  const registeredCount = ev?.registrations_count ?? 0;
  const isFull = !!ev?.capacity && registeredCount >= ev.capacity;
  const brandColor = ev?.brand_color ?? "#6366f1";

  // Called when the user clicks the main "Register" button. Not signed in?
  // Collect a name + email first (no account, no navigating away) — see the
  // "guest" step below — then continue exactly the same way a signed-in
  // user would.
  function handleRegisterClick() {
    if (!user) {
      setRegStep("guest");
      return;
    }
    advancePastGuestStep();
  }

  // Called from the guest form's "Continue" button once name + email look valid.
  function handleGuestContinue() {
    advancePastGuestStep();
  }

  function advancePastGuestStep() {
    if (hasTypes) {
      setRegStep("types");
    } else if (hasSurvey) {
      setRegStep("survey");
    } else {
      register.mutate({ guest: guestPayload() });
    }
  }

  // Called from types selector "Next"
  function handleTypesDone() {
    if (hasSurvey) {
      setRegStep("survey");
    } else {
      register.mutate({ eventTypeIds: selectedTypeIds, guest: guestPayload() });
    }
  }

  // Called from survey "Complete registration"
  function handleSurveyDone(answers: ApiRegistrationAnswer[]) {
    register.mutate({ answers, eventTypeIds: selectedTypeIds, guest: guestPayload() });
  }

  function toggleType(id: string) {
    setSelectedTypeIds((prev) =>
      prev.includes(id) ? prev.filter((x) => x !== id) : [...prev, id],
    );
  }

  function handleJoinWaitlistForType(typeId: string) {
    setWaitlistPendingTypeId(typeId);
    joinWaitlist.mutate({ eventTypeIds: [ typeId ] });
  }

  return (
    <div className="min-h-screen bg-background">
      <SiteHeader />

      {/* Banner */}
      {ev?.banner_url && (
        <div className="relative h-52 w-full overflow-hidden md:h-72">
          <img
            src={ev.banner_url}
            alt={t("common.bannerAlt", { title: ev.title })}
            className="h-full w-full object-cover"
          />
          <div className="absolute inset-0 bg-gradient-to-t from-background/80 to-transparent" />
        </div>
      )}

      <main className="mx-auto max-w-3xl px-5 py-10">
        <Button asChild variant="ghost" size="sm" className="mb-4">
          <Link to="/events">
            <ArrowLeft className="h-4 w-4" /> {t("eventDetail.allEvents")}
          </Link>
        </Button>

        {eventQuery.isLoading && <p className="text-muted-foreground">{t("common.loading")}</p>}
        {eventQuery.isError && <p className="text-muted-foreground">{t("eventDetail.notFound")}</p>}

        {ev && (
          <>
            {/* Logo + title row */}
            <div className="flex items-start gap-4">
              {ev.logo_url && (
                <img
                  src={ev.logo_url}
                  alt={t("common.eventLogoAlt")}
                  className="h-14 w-14 rounded-xl border border-border object-cover shadow-sm flex-shrink-0"
                />
              )}
              <div className="flex-1">
                <div className="flex items-center gap-2">
                  <Badge
                    variant="secondary"
                    style={{
                      backgroundColor: `${brandColor}22`,
                      color: brandColor,
                      borderColor: `${brandColor}44`,
                    }}
                  >
                    {categoryLabel(ev.category)}
                  </Badge>
                  <Badge variant="outline">{formatPrice(ev.price_cents, ev.currency)}</Badge>
                </div>
                <h1 className="mt-2 font-display text-4xl font-bold">{ev.title}</h1>
              </div>
            </div>

            <div className="mt-5 space-y-2 text-muted-foreground">
              <p className="flex items-center gap-2">
                <CalendarDays className="h-5 w-5" /> {formatDateTime(ev.start_at)}
              </p>
              {ev.location && (
                <p className="flex items-center gap-2">
                  <MapPin className="h-5 w-5" /> {ev.location}
                  {ev.latitude != null && ev.longitude != null && (
                    <a
                      href={googleMapsViewUrl(ev.latitude, ev.longitude)}
                      target="_blank"
                      rel="noreferrer"
                      className="inline-flex items-center gap-1 text-sm underline underline-offset-2 hover:text-foreground"
                    >
                      {t("eventDetail.viewOnMap")} <ExternalLink className="h-3.5 w-3.5" />
                    </a>
                  )}
                </p>
              )}
              {ev.route_map_url && (
                <p className="flex items-center gap-2">
                  <Milestone className="h-5 w-5" />
                  <a
                    href={ev.route_map_url}
                    target="_blank"
                    rel="noreferrer"
                    className="inline-flex items-center gap-1 text-sm underline underline-offset-2 hover:text-foreground"
                  >
                    {t("eventDetail.viewRoute")} <ExternalLink className="h-3.5 w-3.5" />
                  </a>
                </p>
              )}
              <p className="flex items-center gap-2">
                <Users className="h-5 w-5" />{" "}
                {ev.capacity
                  ? t("eventDetail.registeredWithCapacity", {
                      count: registeredCount,
                      capacity: ev.capacity,
                    })
                  : t("eventDetail.registeredNoCapacity", { count: registeredCount })}
                {isFull && (
                  <Badge variant="outline" className="ml-1">
                    {t("eventDetail.full")}
                  </Badge>
                )}
              </p>
            </div>

            {ev.description && (
              <p className="mt-6 whitespace-pre-wrap leading-relaxed">{ev.description}</p>
            )}

            {/* Event types preview (outside the reg card) */}
            {hasTypes && regStep === "idle" && (
              <div className="mt-6 space-y-2">
                <p className="text-sm font-medium">{t("eventDetail.availableOptions")}</p>
                <div className="flex flex-wrap gap-2">
                  {ev.event_types.map((et) => {
                    const priceCents = et.price_cents ?? ev.price_cents;
                    return (
                      <div
                        key={et.id}
                        className="flex items-center gap-2 rounded-lg border border-border bg-card px-3 py-1.5 text-sm"
                      >
                        <span className="font-medium">{et.name}</span>
                        <Badge variant="secondary" className="text-xs">
                          {priceCents === 0
                            ? t("common.free")
                            : formatPrice(priceCents, ev.currency)}
                        </Badge>
                        {et.spots_remaining !== null && et.spots_remaining <= 10 && (
                          <span className="text-xs text-muted-foreground">
                            {et.spots_remaining === 0
                              ? t("eventDetail.full")
                              : t("eventDetail.spotsLeft", { count: et.spots_remaining })}
                          </span>
                        )}
                      </div>
                    );
                  })}
                </div>
              </div>
            )}

            {/* Registration card */}
            <div
              className="mt-8 rounded-2xl border p-6"
              style={{ borderColor: `${brandColor}44`, backgroundColor: `${brandColor}0a` }}
            >
              {/* Guest details step — shown before types/survey when not signed in */}
              {regStep === "guest" ? (
                <div className="space-y-4">
                  <div>
                    <p className="font-medium">{t("eventDetail.guestFormTitle")}</p>
                    <p className="text-sm text-muted-foreground">
                      {t("eventDetail.guestFormDesc")}
                    </p>
                  </div>
                  <div className="space-y-2">
                    <Label htmlFor="guest-name">{t("eventDetail.guestName")}</Label>
                    <Input
                      id="guest-name"
                      value={guestName}
                      onChange={(e) => setGuestName(e.target.value)}
                      placeholder={t("eventDetail.guestNamePlaceholder")}
                      autoComplete="name"
                    />
                  </div>
                  <div className="space-y-2">
                    <Label htmlFor="guest-email">{t("eventDetail.guestEmail")}</Label>
                    <Input
                      id="guest-email"
                      type="email"
                      value={guestEmail}
                      onChange={(e) => setGuestEmail(e.target.value)}
                      placeholder={t("eventDetail.guestEmailPlaceholder")}
                      autoComplete="email"
                    />
                  </div>
                  <div className="flex flex-wrap items-center justify-between gap-3">
                    <Button variant="ghost" onClick={() => setRegStep("idle")}>
                      {t("common.back")}
                    </Button>
                    <div className="flex flex-wrap items-center gap-2">
                      <Button variant="outline" onClick={() => navigate({ to: "/auth" })}>
                        {t("eventDetail.signInInstead")}
                      </Button>
                      <Button
                        disabled={!guestValid || register.isPending}
                        onClick={handleGuestContinue}
                        style={{ backgroundColor: brandColor }}
                        className="text-white hover:opacity-90"
                      >
                        {register.isPending && <Loader2 className="h-4 w-4 animate-spin" />}
                        {t("common.continue")}
                      </Button>
                    </div>
                  </div>
                </div>
              ) : regStep === "types" && hasTypes ? (
                <EventTypeSelector
                  eventTypes={ev.event_types}
                  eventPriceCents={ev.price_cents}
                  currency={ev.currency}
                  selectedIds={selectedTypeIds}
                  onToggle={toggleType}
                  onNext={handleTypesDone}
                  onBack={() => setRegStep("idle")}
                  brandColor={brandColor}
                  isPending={register.isPending}
                  nextLabel={hasSurvey ? t("eventDetail.nextSurvey") : t("eventDetail.register")}
                  onJoinWaitlist={handleJoinWaitlistForType}
                  waitlistPendingTypeId={waitlistPendingTypeId}
                />
              ) : regStep === "survey" && ev.survey ? (
                /* Survey step */
                <SurveyForm
                  survey={ev.survey}
                  brandColor={brandColor}
                  isPending={register.isPending}
                  onBack={() => setRegStep(hasTypes ? "types" : "idle")}
                  onSubmit={handleSurveyDone}
                />
              ) : regQuery.data && regQuery.data.payment_status === "unpaid" ? (
                /* Registered, payment still pending */
                <PaymentPanel
                  registrationId={regQuery.data.id}
                  brandColor={brandColor}
                  onPaid={() => {
                    queryClient.invalidateQueries({ queryKey: ["my-reg", eventId] });
                    if (ev) downloadICS(ev);
                  }}
                />
              ) : regQuery.data ? (
                /* Already registered and paid (or free) */
                <div className="flex flex-wrap items-center justify-between gap-4">
                  <div>
                    <p
                      className="flex items-center gap-2 font-medium"
                      style={{ color: brandColor }}
                    >
                      <Check className="h-5 w-5" /> {t("eventDetail.youAreRegistered")}
                    </p>
                    {regQuery.data.event_types?.length > 0 && (
                      <div className="flex flex-wrap gap-1.5 mt-2">
                        {regQuery.data.event_types.map((et) => (
                          <Badge key={et.id} variant="secondary">
                            {et.name}
                          </Badge>
                        ))}
                      </div>
                    )}
                    {regQuery.data.checked_in_at && (
                      <Badge variant="secondary" className="mt-2">
                        {t("dashboard.checkedIn")}
                      </Badge>
                    )}
                    {regQuery.data.finish_time_seconds != null && (
                      <p className="mt-1 text-sm text-muted-foreground">
                        {t("dashboard.yourFinishTime", {
                          time: formatFinishTime(regQuery.data.finish_time_seconds),
                        })}
                      </p>
                    )}
                  </div>
                  <div className="flex flex-wrap items-center gap-2">
                    <RegistrationTicketQR
                      registrationId={regQuery.data.id}
                      eventTitle={ev.title}
                      brandColor={brandColor}
                    />
                    <Button variant="outline" onClick={() => downloadICS(ev)}>
                      <Download className="h-4 w-4" /> {t("eventDetail.addToCalendar")}
                    </Button>
                  </div>
                  <div className="flex flex-wrap items-center gap-2">
                    {regQuery.data.certificate_url && (
                      <Button asChild variant="outline">
                        <a href={regQuery.data.certificate_url} target="_blank" rel="noreferrer">
                          <Award className="h-4 w-4" /> {t("eventDetail.downloadCertificate")}
                        </a>
                      </Button>
                    )}
                    <Button variant="outline" onClick={() => downloadICS(ev)}>
                      <Download className="h-4 w-4" /> {t("eventDetail.addToCalendar")}
                    </Button>
                  </div>
                </div>
              ) : waitlistQuery.data ? (
                /* On the waitlist — not registered yet, waiting for a spot */
                <div className="flex flex-wrap items-center justify-between gap-4">
                  <div>
                    <p
                      className="flex items-center gap-2 font-medium"
                      style={{ color: brandColor }}
                    >
                      <Hourglass className="h-5 w-5" /> {t("eventDetail.onWaitlist")}
                    </p>
                    <p className="mt-1 text-sm text-muted-foreground">
                      {t("eventDetail.onWaitlistDesc")}
                    </p>
                  </div>
                  <Button
                    variant="outline"
                    disabled={leaveWaitlist.isPending}
                    onClick={() => leaveWaitlist.mutate(waitlistQuery.data!.id)}
                  >
                    {leaveWaitlist.isPending && <Loader2 className="h-4 w-4 animate-spin" />}
                    {t("eventDetail.leaveWaitlist")}
                  </Button>
                </div>
              ) : isFull && !user && !loading ? (
                /* Event full — joining the waitlist still requires an
                   account (unlike registering, which now supports guest
                   checkout above), so this is the one case that still
                   sends a signed-out visitor to sign in first. */
                <div className="flex flex-wrap items-center justify-between gap-4">
                  <p className="text-muted-foreground">{t("eventDetail.signInPrompt")}</p>
                  <Button
                    onClick={() => navigate({ to: "/auth" })}
                    style={{ backgroundColor: brandColor }}
                    className="text-white hover:opacity-90"
                  >
                    {t("eventDetail.signInToRegister")}
                  </Button>
                </div>
              ) : (
                /* Default: register button */
                <div className="flex flex-wrap items-center justify-between gap-4">
                  <div>
                    <p className="font-medium">
                      {hasTypes
                        ? t("eventDetail.selectTypePricing")
                        : ev.price_cents === 0
                          ? t("eventDetail.freeRegistration")
                          : formatPrice(ev.price_cents, ev.currency)}
                    </p>
                    {!hasTypes && ev.price_cents > 0 && (
                      <p className="text-sm text-muted-foreground">
                        {t("eventDetail.payInstantly")}
                      </p>
                    )}
                    {hasTypes && (
                      <p className="text-sm text-muted-foreground">
                        {t("eventDetail.optionsAvailable", { count: ev.event_types.length })}
                      </p>
                    )}
                    {hasSurvey && (
                      <p className="text-sm text-muted-foreground mt-1">
                        {t("eventDetail.includesSurvey", {
                          count: ev.survey!.questions.length,
                        })}
                      </p>
                    )}
                  </div>
                  <Button
                    disabled={register.isPending || joinWaitlist.isPending}
                    onClick={isFull ? () => joinWaitlist.mutate(undefined) : handleRegisterClick}
                    style={isFull ? undefined : { backgroundColor: brandColor }}
                    variant={isFull ? "outline" : undefined}
                    className={isFull ? undefined : "text-white hover:opacity-90 disabled:opacity-50"}
                  >
                    {(register.isPending || joinWaitlist.isPending) && (
                      <Loader2 className="h-4 w-4 animate-spin" />
                    )}
                    {isFull ? t("eventDetail.joinWaitlist") : t("eventDetail.register")}
                  </Button>
                </div>
              )}
            </div>

            {/* Results — auto-shown once an organizer has recorded any */}
            {leaderboardQuery.data && (
              <ResultsLeaderboard
                groups={leaderboardQuery.data}
                currentUserId={user?.id}
                brandColor={brandColor}
              />
            )}

            {/* QR code */}
            <div className="mt-8 rounded-2xl border border-border bg-card p-6">
              <div className="flex items-center gap-2 mb-3">
                <QrCode className="h-5 w-5 text-muted-foreground" />
                <h2 className="font-semibold">{t("eventDetail.shareEvent")}</h2>
              </div>
              <p className="text-sm text-muted-foreground mb-5">{t("eventDetail.shareDesc")}</p>
              <EventQRCode eventId={eventId} brandColor={brandColor} />
            </div>
          </>
        )}
      </main>
    </div>
  );
}
