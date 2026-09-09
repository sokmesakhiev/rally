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
  Award,
  Ban
} from "lucide-react";
import { toast } from "sonner";
import { useTranslation } from "react-i18next";
import {
  eventsApi,
  registrationsApi,
  waitlistApi,
  resultsApi,
  type ApiRegistrationAnswer,
  type ApiRegistration,
  type GuestContact,
} from "@/lib/api-client";
import { useAuth } from "@/lib/use-auth";
import { SiteHeader } from "@/components/site-header";
import { PresentedBy } from "@/components/presented-by";
import { EventQRCode } from "@/components/event-qr-code";
import { RegistrationTicketQR } from "@/components/registration-ticket-qr";
import { SurveyForm } from "@/components/survey-form";
import { EventTypeSelector } from "@/components/event-type-selector";
import { PaymentPanel } from "@/components/payment-panel";
import { PushNotificationPrompt } from "@/components/push-notification-prompt";
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
  loader: async ({ params }) => {
    const { event } = await eventsApi.get(params.eventId);
    return { event };
  },
  head: ({ loaderData }) => {
    const event = loaderData?.event;

    if (!event) {
      return { meta: [{ title: "Event — Rally" }] };
    }

    const title = `${event.title} — Rally`;
    const description = event.description
      ? `${event.description.substring(0, 160)}${event.description.length > 160 ? "..." : ""}`
      : `Join ${event.title} on ${formatDateTime(event.start_at)}. ${categoryLabel(event.category)} event in ${event.location || "Cambodia"}.`;
    const imageUrl = event.banner_url || event.logo_url || undefined;
    const baseUrl = import.meta.env.VITE_BASE_URL || "";

    // JSON-LD structured data for events
    const structuredData = {
      "@context": "https://schema.org",
      "@type": "Event",
      name: event.title,
      description: event.description || description,
      startDate: event.start_at,
      endDate: event.end_at || event.start_at,
      location: event.location
        ? {
            "@type": "Place",
            name: event.location,
            ...(event.latitude && event.longitude
              ? {
                  geo: {
                    "@type": "GeoCoordinates",
                    latitude: event.latitude,
                    longitude: event.longitude,
                  },
                }
              : null),
          }
        : undefined,
      organizer: event.organization
        ? {
            "@type": "Organization",
            name: event.organization.name,
            url: `${baseUrl}/organizers/${event.organization.slug}`,
          }
        : undefined,
      image: imageUrl,
      offers: event.price_cents > 0
        ? {
            "@type": "Offer",
            price: (event.price_cents / 100).toFixed(2),
            priceCurrency: event.currency.toUpperCase(),
            availability: "https://schema.org/InStock",
          }
        : {
            "@type": "Offer",
            price: "0",
            priceCurrency: event.currency.toUpperCase(),
            availability: "https://schema.org/InStock",
          },
    };

    return {
      meta: [
        { title },
        { name: "description", content: description },
        { property: "og:title", content: title },
        { property: "og:description", content: description },
        { property: "og:type", content: "website" },
        ...(imageUrl ? [{ property: "og:image", content: imageUrl }] : []),
        { name: "twitter:card", content: "summary_large_image" },
        { name: "twitter:title", content: title },
        { name: "twitter:description", content: description },
        ...(imageUrl ? [{ name: "twitter:image", content: imageUrl }] : []),
        ...(baseUrl ? [{ rel: "canonical", href: `${baseUrl}/events/${event.id}` }] : []),
      ],
      scripts: [
        {
          type: "application/ld+json",
          innerHTML: JSON.stringify(structuredData),
        },
      ],
    };
  },
  component: EventDetail,
});

// Registration steps:
//   idle → (guest, if not signed in) → (types if event has types) → (survey if event has survey)
//   → (confirm, if the selected total is > 0 — see registration-flow-review-2026-08-24.md) → done
type RegStep = "idle" | "guest" | "types" | "survey" | "confirm";

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
// Deliberately lenient — mirrors Profile's own format check on the backend.
// Cambodian numbers show up as "012 345 678", "+855 12 345 678", etc., and
// this form isn't the place to enforce one canonical shape.
const PHONE_RE = /^[+]?[\d\s-]{7,20}$/;

function EventDetail() {
  const { eventId } = Route.useParams();
  const { t } = useTranslation();
  const { user, loading } = useAuth();
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const { event } = Route.useLoaderData();

  const [regStep, setRegStep] = useState<RegStep>("idle");
  // Guest checkout never signs the visitor in (see registrationsApi.create)
  // — regQuery below only runs for a signed-in user, so a guest's own
  // just-created registration is held here instead, entirely client-side.
  // It won't survive a page refresh; the confirmation email is the durable
  // record for a guest, same as a store's "check your email for your
  // order" pattern.
  const [guestRegistration, setGuestRegistration] = useState<ApiRegistration | null>(null);
  const [selectedTypeIds, setSelectedTypeIds] = useState<string[]>([]);
  // Collected on the survey step, then held until the confirm step (or,
  // when no confirm step applies, submitted immediately) — see
  // proceedPastLastStep below.
  const [pendingAnswers, setPendingAnswers] = useState<ApiRegistrationAnswer[]>([]);
  const [guestName, setGuestName] = useState("");
  const [guestEmail, setGuestEmail] = useState("");
  const [guestPhone, setGuestPhone] = useState("");
  // Phone is Cambodia's most common contact channel — a first-class
  // alternative to email here, not a fallback. At least one of the two
  // (plus a name) is required; either alone is enough.
  const guestEmailValid = guestEmail.trim().length === 0 || EMAIL_RE.test(guestEmail.trim());
  const guestPhoneValid = guestPhone.trim().length === 0 || PHONE_RE.test(guestPhone.trim());
  const guestHasContact =
    (guestEmail.trim().length > 0 && guestEmailValid) ||
    (guestPhone.trim().length > 0 && guestPhoneValid);
  const guestValid = guestName.trim().length > 0 && guestHasContact;

  // Only actually sent to the backend when there's no signed-in user — see
  // registrationsApi.create.
  function guestPayload() {
    if (user) return undefined;
    return {
      name: guestName.trim(),
      email: guestEmail.trim() || undefined,
      phone: guestPhone.trim() || undefined,
    };
  }

  // Same contact info, reused to authorize the payment step for a guest
  // (no session to authorize it with instead) — see paymentsApi.create/status.
  function guestContact(): GuestContact | undefined {
    if (user) return undefined;
    return {
      email: guestEmail.trim() || undefined,
      phone: guestPhone.trim() || undefined,
    };
  }

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
      guest?: { name: string; email?: string; phone?: string };
    }) => registrationsApi.create(eventId, opts),
    onSuccess: (res) => {
      setRegStep("idle");
      setSelectedTypeIds([]);
      setPendingAnswers([]);
      // Guest checkout never signs the visitor in (see
      // registrationsApi.create) — hold onto the new registration directly
      // instead of relying on regQuery, which only runs for a signed-in
      // user.
      if (!user) {
        setGuestRegistration(res.registration);
      } else {
        queryClient.invalidateQueries({ queryKey: ["my-reg", eventId] });
      }
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
      } else {
        toast.error(e.message ?? t("eventDetail.toastRegisterError"));
      }
    },
  });

  const ev = event;
  // A signed-in user's registration comes from regQuery; a guest's comes
  // from client-side state set after registering (see the register
  // mutation above) since there's no session for regQuery to authenticate
  // with.
  const activeReg = user ? regQuery.data : guestRegistration;
  const hasTypes = !!ev?.event_types?.length;
  const hasSurvey = !!ev?.survey?.questions?.length;
  const registeredCount = ev?.registrations_count ?? 0;
  const isFull = !!ev?.capacity && registeredCount >= ev.capacity;
  const brandColor = ev?.brand_color ?? "#6366f1";

  // What the current selection actually costs — the flat event price, or
  // the sum of selected types' own prices (falling back to the flat price
  // per-type when a type has none of its own). Drives whether a "confirm
  // before you pay" step is inserted — see registration-flow-review-2026-08-24.md.
  const totalDueCents = !ev
    ? 0
    : hasTypes
      ? ev.event_types
          .filter((et) => selectedTypeIds.includes(et.id))
          .reduce((sum, et) => sum + (et.price_cents ?? ev.price_cents), 0)
      : ev.price_cents;
  const requiresConfirm = totalDueCents > 0;

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
      proceedPastLastStep([]);
    }
  }

  // Called from types selector "Next"
  function handleTypesDone() {
    if (hasSurvey) {
      setRegStep("survey");
    } else {
      proceedPastLastStep([]);
    }
  }

  // Called from survey "Complete registration"
  function handleSurveyDone(answers: ApiRegistrationAnswer[]) {
    proceedPastLastStep(answers);
  }

  // Common tail of every path (guest-only, guest+types, +survey, ...) once
  // there's nothing left to collect. Paid selections (event or guest —
  // both, per registration-flow-review-2026-08-24.md) get one more step to
  // review what they entered before the charge happens; free ones register
  // immediately exactly like before.
  function proceedPastLastStep(answers: ApiRegistrationAnswer[]) {
    setPendingAnswers(answers);
    if (requiresConfirm) {
      setRegStep("confirm");
    } else {
      register.mutate({ answers, eventTypeIds: selectedTypeIds, guest: guestPayload() });
    }
  }

  // Called from the confirm step's "Confirm & register" button.
  function handleConfirmRegister() {
    register.mutate({
      answers: pendingAnswers,
      eventTypeIds: selectedTypeIds,
      guest: guestPayload(),
    });
  }

  // Where "Back" on the confirm step should return to — whichever step was
  // actually last shown before landing here.
  function confirmBackTarget(): RegStep {
    if (hasSurvey) return "survey";
    if (hasTypes) return "types";
    return user ? "idle" : "guest";
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

      {/* Banner — hidden for the same suspended-and-stranger case the "no
          longer available" state below covers, so a scam listing's own
          banner image doesn't render for exactly the audience a suspension is
          meant to protect. */}
      {ev?.banner_url && !(ev.suspended && !ev.role) && (
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

        {!event && <p className="text-muted-foreground">{t("eventDetail.notFound")}</p>}

        {/* A suspended event still 200s for a direct link (see
            ApplicationController#identify_current_user!/EventAuthorization's
            read allowlist) so the owner/team can still see it — but a
            stranger following an old link to a suspended event shouldn't see
            the full page, since a stranger is exactly who a scam listing was
            trying to reach. `ev.role` is only ever set for the
            creator/a team member (see ApiEvent.role's doc comment), so its
            absence here means "anonymous viewer or signed-in stranger". */}
        {ev && ev.suspended && !ev.role && (
          <div className="mt-10 rounded-2xl border border-border bg-muted/30 p-10 text-center">
            <Ban className="mx-auto h-8 w-8 text-muted-foreground" />
            <p className="mt-4 text-lg font-semibold">{t("eventDetail.suspendedTitle")}</p>
            <p className="mt-2 text-sm text-muted-foreground">{t("eventDetail.suspendedDesc")}</p>
          </div>
        )}

        {ev && !(ev.suspended && !ev.role) && (
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

            {/* Sits below the event's own hero branding, never inside it —
                the two brandings are shown in different places by design
                (organization-identity-tickets.md's Ticket H). */}
            <PresentedBy organization={ev.organization} />

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
                    <Label htmlFor="guest-phone">{t("eventDetail.guestPhone")}</Label>
                    <Input
                      id="guest-phone"
                      type="tel"
                      value={guestPhone}
                      onChange={(e) => setGuestPhone(e.target.value)}
                      placeholder={t("eventDetail.guestPhonePlaceholder")}
                      autoComplete="tel"
                    />
                  </div>
                  <div className="space-y-2">
                    <Label htmlFor="guest-email">
                      {t("eventDetail.guestEmail")}{" "}
                      <span className="text-muted-foreground font-normal">
                        {t("eventDetail.guestEmailOrPhoneNote")}
                      </span>
                    </Label>
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
                  nextLabel={
                    hasSurvey
                      ? t("eventDetail.nextSurvey")
                      : requiresConfirm
                        ? t("eventDetail.reviewAndConfirm")
                        : t("eventDetail.register")
                  }
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
                  submitLabel={requiresConfirm ? t("eventDetail.reviewAndConfirm") : undefined}
                />
              ) : regStep === "confirm" ? (
                /* Confirm step — shown only for paid selections (event or
                   guest checkout, per registration-flow-review-2026-08-24.md)
                   right before the actual POST /registrations call, so a
                   typo'd contact or wrong event type gets caught before the
                   charge instead of after. */
                <div className="space-y-5">
                  <div>
                    <p className="font-medium">{t("eventDetail.confirmTitle")}</p>
                    <p className="text-sm text-muted-foreground">
                      {t("eventDetail.confirmDesc")}
                    </p>
                  </div>

                  <div className="space-y-3 rounded-xl border border-border bg-card p-4 text-sm">
                    <div className="flex items-center justify-between gap-3">
                      <span className="text-muted-foreground">{t("eventDetail.confirmName")}</span>
                      <span className="font-medium">
                        {user ? user.display_name || t("eventDetail.confirmNoName") : guestName}
                      </span>
                    </div>
                    <div className="flex items-center justify-between gap-3">
                      <span className="text-muted-foreground">
                        {t("eventDetail.confirmContact")}
                      </span>
                      <span className="font-medium">
                        {user
                          ? [
                              user.phone,
                              user.email_auto_generated ? null : user.email,
                            ]
                              .filter(Boolean)
                              .join(" · ") || t("eventDetail.confirmNoContact")
                          : [guestPhone.trim(), guestEmail.trim()].filter(Boolean).join(" · ")}
                      </span>
                    </div>
                    {hasTypes && (
                      <div className="flex items-start justify-between gap-3">
                        <span className="text-muted-foreground">
                          {t("eventDetail.confirmSelectedTypes")}
                        </span>
                        <span className="text-right font-medium">
                          {ev.event_types
                            .filter((et) => selectedTypeIds.includes(et.id))
                            .map((et) => et.name)
                            .join(", ")}
                        </span>
                      </div>
                    )}
                    <div className="flex items-center justify-between gap-3 border-t border-border pt-3">
                      <span className="text-muted-foreground">{t("eventDetail.confirmTotal")}</span>
                      <span className="text-base font-semibold" style={{ color: brandColor }}>
                        {formatPrice(totalDueCents, ev.currency)}
                      </span>
                    </div>
                  </div>

                  <p className="rounded-lg bg-muted/50 px-4 py-3 text-xs text-muted-foreground">
                    {t("eventDetail.nonRefundableNotice")}
                  </p>

                  <div className="flex gap-3">
                    <Button
                      type="button"
                      variant="outline"
                      disabled={register.isPending}
                      onClick={() => setRegStep(confirmBackTarget())}
                    >
                      {t("common.back")}
                    </Button>
                    <Button
                      type="button"
                      disabled={register.isPending}
                      onClick={handleConfirmRegister}
                      style={{ backgroundColor: brandColor }}
                      className="flex-1 text-white hover:opacity-90 disabled:opacity-50"
                    >
                      {register.isPending && <Loader2 className="h-4 w-4 animate-spin" />}
                      {t("eventDetail.confirmAndRegister")}
                    </Button>
                  </div>
                </div>
              ) : activeReg && activeReg.payment_status === "unpaid" ? (
                /* Registered, payment still pending */
                <PaymentPanel
                  registrationId={activeReg.id}
                  brandColor={brandColor}
                  guestContact={guestContact()}
                  onPaid={() => {
                    if (user) {
                      queryClient.invalidateQueries({ queryKey: ["my-reg", eventId] });
                    } else {
                      // No session to refetch from — update the client-side
                      // copy directly (see guestRegistration above).
                      setGuestRegistration((prev) =>
                        prev ? { ...prev, payment_status: "paid" } : prev,
                      );
                    }
                    if (ev) downloadICS(ev);
                  }}
                />
              ) : activeReg ? (
                /* Already registered and paid (or free) */
                <div className="space-y-4">
                {/* The one moment the ask is concrete rather than abstract —
                    they've just committed to an event and there's something
                    specific to be told about. Renders nothing unless the
                    browser supports push, the server has VAPID keys, and they
                    haven't already subscribed or been denied. The permission
                    prompt only fires on click, never on mount. */}
                <PushNotificationPrompt brandColor={brandColor} />

                <div className="flex flex-wrap items-center justify-between gap-4">
                  <div>
                    <p
                      className="flex items-center gap-2 font-medium"
                      style={{ color: brandColor }}
                    >
                      <Check className="h-5 w-5" /> {t("eventDetail.youAreRegistered")}
                    </p>
                    {activeReg.event_types?.length > 0 && (
                      <div className="flex flex-wrap gap-1.5 mt-2">
                        {activeReg.event_types.map((et) => (
                          <Badge key={et.id} variant="secondary">
                            {et.name}
                          </Badge>
                        ))}
                      </div>
                    )}
                    {activeReg.checked_in_at && (
                      <Badge variant="secondary" className="mt-2">
                        {t("dashboard.checkedIn")}
                      </Badge>
                    )}
                    {activeReg.finish_time_seconds != null && (
                      <p className="mt-1 text-sm text-muted-foreground">
                        {t("dashboard.yourFinishTime", {
                          time: formatFinishTime(activeReg.finish_time_seconds),
                        })}
                      </p>
                    )}
                  </div>
                  <div className="flex flex-wrap items-center gap-2">
                    <RegistrationTicketQR
                      registrationId={activeReg.id}
                      eventTitle={ev.title}
                      brandColor={brandColor}
                    />
                    {activeReg.certificate_url && (
                      <Button asChild variant="outline">
                        <a href={activeReg.certificate_url} target="_blank" rel="noreferrer">
                          <Award className="h-4 w-4" /> {t("eventDetail.downloadCertificate")}
                        </a>
                      </Button>
                    )}
                    <Button variant="outline" onClick={() => downloadICS(ev)}>
                      <Download className="h-4 w-4" /> {t("eventDetail.addToCalendar")}
                    </Button>
                  </div>
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
