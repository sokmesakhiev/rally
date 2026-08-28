import { createFileRoute, useNavigate, Link } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useEffect, useState } from "react";
import { ArrowLeft, Loader2 } from "lucide-react";
import { toast } from "sonner";
import { useTranslation } from "react-i18next";
import {
  eventsApi,
  organizationsApi,
  surveysApi,
  type SurveyQuestionDraft,
  type ApiEventTypeDraft,
} from "@/lib/api-client";
import { useAuth } from "@/lib/use-auth";
import { SurveyBuilder } from "@/components/survey-builder";
import { EventTypeBuilder, newEventType } from "@/components/event-type-builder";
import { PaidEventGate } from "@/components/paid-event-gate";
import { SiteHeader } from "@/components/site-header";
import { ImageUpload } from "@/components/image-upload";
import { LocationPicker } from "@/components/location-picker";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { Switch } from "@/components/ui/switch";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { eventCategoryOptions } from "@/lib/event-utils";

export const Route = createFileRoute("/_authenticated/events/new")({
  head: () => ({ meta: [{ title: "Create event — Rally" }] }),
  component: NewEvent,
});

const PRESET_COLORS = [
  "#6366f1", // indigo
  "#8b5cf6", // violet
  "#ec4899", // pink
  "#ef4444", // red
  "#f97316", // orange
  "#eab308", // yellow
  "#22c55e", // green
  "#06b6d4", // cyan
  "#0ea5e9", // sky
  "#64748b", // slate
];

function NewEvent() {
  const { t } = useTranslation();
  const { user } = useAuth();
  const navigate = useNavigate();
  const queryClient = useQueryClient();

  // Basic fields
  // Which organization presents this event. Always an explicit choice — a
  // user may administer several, and guessing would publish under the wrong
  // brand, the exact failure organizations exist to prevent.
  const [organizationSlug, setOrganizationSlug] = useState<string | null>(null);

  const organizationsQuery = useQuery({
    queryKey: ["organizations"],
    queryFn: () => organizationsApi.list().then((r) => r.organizations),
  });
  const organizations = organizationsQuery.data ?? [];

  // Default to the last one they worked in, falling back to the first.
  useEffect(() => {
    if (organizationSlug || organizations.length === 0) return;
    const remembered = localStorage.getItem("rally_last_organization");
    const match = organizations.find((o) => o.slug === remembered);
    setOrganizationSlug(match?.slug ?? organizations[0].slug);
  }, [organizations, organizationSlug]);

  const selectedOrganization = organizations.find((o) => o.slug === organizationSlug) ?? null;

  const [title, setTitle] = useState("");
  const [description, setDescription] = useState("");
  const [category, setCategory] = useState("running");
  const [location, setLocation] = useState("");
  const [latitude, setLatitude] = useState<number | null>(null);
  const [longitude, setLongitude] = useState<number | null>(null);
  const [routeMapUrl, setRouteMapUrl] = useState("");
  const [startAt, setStartAt] = useState("");
  const [endAt, setEndAt] = useState("");
  const [isPaid, setIsPaid] = useState(false);
  const [price, setPrice] = useState("");

  // Branding fields
  const [brandColor, setBrandColor] = useState("#6366f1");
  const [bannerUrl, setBannerUrl] = useState<string | null>(null);
  const [logoUrl, setLogoUrl] = useState<string | null>(null);

  // Survey fields
  const [hasSurvey, setHasSurvey] = useState(false);
  const [surveyTitle, setSurveyTitle] = useState(t("eventForm.defaultSurveyTitle"));
  const [surveyQuestions, setSurveyQuestions] = useState<SurveyQuestionDraft[]>([
    { question_text: "", question_type: "text", options: [], required: false },
  ]);

  // Event type fields
  const [hasEventTypes, setHasEventTypes] = useState(false);
  const [eventTypes, setEventTypes] = useState<ApiEventTypeDraft[]>([newEventType(0)]);

  const eventPriceCents = isPaid && price ? Math.round(Number(price) * 100) : 0;

  const mutation = useMutation({
    mutationFn: async () => {
      // 1. Optionally create the survey first
      let surveyId: string | null = null;
      if (hasSurvey && surveyQuestions.some((q) => q.question_text.trim())) {
        const { survey } = await surveysApi.create(surveyTitle, surveyQuestions);
        surveyId = survey.id;
      }

      // 2. Build event types payload
      const eventTypesAttrs = hasEventTypes
        ? eventTypes.filter((t) => t.name.trim()).map((t, i) => ({ ...t, position: i }))
        : [];

      // 3. Create the event
      const { event } = await eventsApi.create({
        organization_id: selectedOrganization!.id,
        title: title.trim(),
        description: description.trim() || null,
        category,
        location: location.trim() || null,
        latitude,
        longitude,
        route_map_url: routeMapUrl.trim() || null,
        start_at: new Date(startAt).toISOString(),
        end_at: endAt ? new Date(endAt).toISOString() : null,
        price_cents: isPaid ? Math.round(Number(price) * 100) : 0,
        currency: "usd",
        brand_color: brandColor,
        banner_url: bannerUrl,
        logo_url: logoUrl,
        ...(surveyId ? { survey_id: surveyId } : {}),
        ...(eventTypesAttrs.length ? { event_types_attributes: eventTypesAttrs } : {}),
      });
      return event;
    },
    onSuccess: (data) => {
      queryClient.invalidateQueries({ queryKey: ["my-events"] });
      toast.success(t("eventForm.toastDraftSaved"));
      navigate({ to: "/dashboard/events/$eventId", params: { eventId: data.id } });
    },
    onError: (e: any) => toast.error(e.message ?? t("eventForm.toastCreateError")),
  });

  const submit = (e: React.FormEvent) => {
    e.preventDefault();
    // Guarded here as well as in the UI: the payload asserts a selection
    // (`selectedOrganization!.id`), so submitting without one would throw
    // rather than surface a message.
    if (!selectedOrganization) return toast.error(t("eventForm.errorPickOrganization"));
    if (!title.trim()) return toast.error(t("eventForm.errorAddTitle"));
    if (!startAt) return toast.error(t("eventForm.errorAddStart"));
    if (endAt && new Date(endAt) <= new Date(startAt))
      return toast.error(t("eventForm.errorEndAfterStart"));
    if (isPaid && (!price || Number(price) <= 0))
      return toast.error(t("eventForm.errorValidPrice"));
    mutation.mutate();
  };

  return (
    <div className="min-h-screen bg-background">
      <SiteHeader />
      <main className="mx-auto max-w-2xl px-5 py-10">
        <Button asChild variant="ghost" size="sm" className="mb-4">
          <Link to="/dashboard">
            <ArrowLeft className="h-4 w-4" /> {t("manageEvent.backToDashboard")}
          </Link>
        </Button>
        <h1 className="font-display text-3xl font-bold">{t("eventForm.title")}</h1>
        <p className="mt-1 text-muted-foreground">{t("eventForm.subtitle")}</p>

        <form onSubmit={submit} className="mt-8 space-y-5">
          {/* ── Presented by ──
              A dropdown only when there's a real choice to make; with one
              organization this is a label, and with none the organizer is
              sent to create one first (an event has to be presented by
              something — see the publish gate in #334). */}
          {!organizationsQuery.isLoading && organizations.length === 0 ? (
            <div className="rounded-2xl border border-border bg-muted/30 p-4">
              <p className="text-sm font-medium">{t("eventForm.noOrganizationTitle")}</p>
              <p className="mt-1 text-sm text-muted-foreground">
                {t("eventForm.noOrganizationDesc")}
              </p>
              <Button asChild variant="outline" size="sm" className="mt-3">
                <Link to="/organizations">{t("eventForm.createOrganization")}</Link>
              </Button>
            </div>
          ) : (
            <div className="space-y-2">
              <Label htmlFor="organization">{t("eventForm.presentedBy")}</Label>
              {organizations.length > 1 ? (
                <Select
                  value={organizationSlug ?? undefined}
                  onValueChange={setOrganizationSlug}
                >
                  <SelectTrigger id="organization">
                    <SelectValue placeholder={t("eventForm.presentedByPlaceholder")} />
                  </SelectTrigger>
                  <SelectContent>
                    {organizations.map((o) => (
                      <SelectItem key={o.slug} value={o.slug}>
                        {o.name}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              ) : (
                <p className="rounded-md border border-input px-3 py-2 text-sm">
                  {selectedOrganization?.name ?? t("common.loading")}
                </p>
              )}
            </div>
          )}

          {/* ── Basic details ── */}
          <div className="space-y-2">
            <Label htmlFor="title">{t("eventForm.eventTitle")}</Label>
            <Input
              id="title"
              value={title}
              onChange={(e) => setTitle(e.target.value)}
              placeholder={t("eventForm.titlePlaceholder")}
              maxLength={120}
            />
          </div>

          <div className="space-y-2">
            <Label htmlFor="desc">{t("eventForm.description")}</Label>
            <Textarea
              id="desc"
              value={description}
              onChange={(e) => setDescription(e.target.value)}
              placeholder={t("eventForm.descPlaceholder")}
              rows={4}
            />
          </div>

          <div className="space-y-2">
            <Label>{t("eventForm.category")}</Label>
            <Select value={category} onValueChange={setCategory}>
              <SelectTrigger>
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {eventCategoryOptions().map((c) => (
                  <SelectItem key={c.value} value={c.value}>
                    {c.label}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>

          <LocationPicker
            value={{ location, latitude, longitude }}
            onChange={(v) => {
              setLocation(v.location);
              setLatitude(v.latitude);
              setLongitude(v.longitude);
            }}
          />

          <div className="space-y-2">
            <Label htmlFor="route-map">{t("eventForm.routeMapUrl")}</Label>
            <Input
              id="route-map"
              type="url"
              value={routeMapUrl}
              onChange={(e) => setRouteMapUrl(e.target.value)}
              placeholder={t("eventForm.routeMapUrlPlaceholder")}
            />
            <p className="text-xs text-muted-foreground">{t("eventForm.routeMapUrlHint")}</p>
          </div>

          <div className="grid gap-5 sm:grid-cols-2">
            <div className="space-y-2">
              <Label htmlFor="start">{t("eventForm.starts")}</Label>
              <Input
                id="start"
                type="datetime-local"
                value={startAt}
                onChange={(e) => setStartAt(e.target.value)}
              />
            </div>
            <div className="space-y-2">
              <Label htmlFor="end">{t("eventForm.endsOptional")}</Label>
              <Input
                id="end"
                type="datetime-local"
                value={endAt}
                onChange={(e) => setEndAt(e.target.value)}
              />
            </div>
          </div>

          <PaidEventGate
            verified={Boolean(user?.verified)}
            isPaid={isPaid}
            onIsPaidChange={setIsPaid}
          />

          {isPaid && (
            <div className="space-y-2">
              <Label htmlFor="price">{t("eventForm.price")}</Label>
              <Input
                id="price"
                type="number"
                min="0"
                step="0.01"
                value={price}
                onChange={(e) => setPrice(e.target.value)}
                placeholder={t("eventForm.pricePlaceholder")}
              />
            </div>
          )}

          <div className="rounded-xl border border-dashed border-border p-4 text-sm text-muted-foreground">
            {t("eventForm.capacityNote")}
          </div>

          {/* ── Branding ── */}
          <div className="rounded-xl border border-border p-5 space-y-5">
            <div>
              <h2 className="font-semibold">{t("manageEvent.brandingTitle")}</h2>
              <p className="text-sm text-muted-foreground">{t("eventForm.brandingDesc")}</p>
            </div>

            <ImageUpload
              value={bannerUrl}
              onChange={setBannerUrl}
              variant="banner"
              label={t("manageEvent.bannerImage")}
            />

            <div className="flex flex-wrap gap-6">
              <ImageUpload
                value={logoUrl}
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
                        borderColor: brandColor === c ? "white" : "transparent",
                        outline: brandColor === c ? `2px solid ${c}` : "none",
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
                      value={brandColor}
                      onChange={(e) => setBrandColor(e.target.value)}
                      className="sr-only"
                    />
                    +
                  </label>
                </div>
                <div className="flex items-center gap-2 mt-1">
                  <span
                    className="inline-block h-5 w-5 rounded-full border border-border"
                    style={{ backgroundColor: brandColor }}
                  />
                  <span className="text-xs text-muted-foreground font-mono">{brandColor}</span>
                </div>
              </div>
            </div>
          </div>

          {/* ── Event types ── */}
          <div className="rounded-xl border border-border p-5 space-y-4">
            <div className="flex items-center justify-between">
              <div>
                <h2 className="font-semibold">{t("eventForm.eventTypesTitle")}</h2>
                <p className="text-sm text-muted-foreground">{t("eventForm.eventTypesDesc")}</p>
              </div>
              <Switch checked={hasEventTypes} onCheckedChange={setHasEventTypes} />
            </div>

            {hasEventTypes && (
              <EventTypeBuilder
                types={eventTypes}
                onTypesChange={setEventTypes}
                eventPriceCents={eventPriceCents}
                allowPricing={Boolean(user?.verified)}
              />
            )}
          </div>

          {/* ── Survey ── */}
          <div className="rounded-xl border border-border p-5 space-y-4">
            <div className="flex items-center justify-between">
              <div>
                <h2 className="font-semibold">{t("eventForm.surveyTitle")}</h2>
                <p className="text-sm text-muted-foreground">{t("eventForm.surveyDesc")}</p>
              </div>
              <Switch checked={hasSurvey} onCheckedChange={setHasSurvey} />
            </div>

            {hasSurvey && (
              <SurveyBuilder
                title={surveyTitle}
                onTitleChange={setSurveyTitle}
                questions={surveyQuestions}
                onQuestionsChange={setSurveyQuestions}
              />
            )}
          </div>

          <Button
            type="submit"
            variant="hero"
            size="lg"
            className="w-full"
            disabled={mutation.isPending}
          >
            {mutation.isPending && <Loader2 className="h-4 w-4 animate-spin" />}
            {t("eventForm.saveDraft")}
          </Button>
        </form>
      </main>
    </div>
  );
}
