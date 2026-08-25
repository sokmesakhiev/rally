/**
 * EventDetailsEditor — lets an organizer correct an event's core details
 * (title, description, category, location, dates, price) after creation.
 *
 * Until this existed, the manage-event page only allowed editing branding
 * (colour/banner/logo), even though the backend's EventsController#update has
 * always accepted the full event shape — so a typo in a title or a wrong start
 * time could only be fixed by deleting and recreating the event.
 *
 * Deliberately does NOT expose `capacity`, `plan`, or `is_published`: those are
 * set by the publish/plan-payment flow (EventPlanPayment#mark_paid!) and are
 * excluded from EventUpdateRequestSchema server-side, so offering them here
 * would be a field that silently does nothing.
 */
import { useEffect, useState } from "react";
import { Loader2 } from "lucide-react";
import { useTranslation } from "react-i18next";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";

import { eventsApi, type ApiEvent, type ApiEventTypeDraft } from "@/lib/api-client";
import { eventCategoryOptions } from "@/lib/event-utils";
import { EventTypeBuilder, newEventType } from "@/components/event-type-builder";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Switch } from "@/components/ui/switch";
import { Textarea } from "@/components/ui/textarea";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";

/**
 * An ISO timestamp to the `YYYY-MM-DDTHH:mm` a datetime-local input needs.
 *
 * Uses local-time getters rather than `toISOString().slice(0, 16)`, which would
 * silently shift the displayed time by the viewer's UTC offset — an organizer
 * in Phnom Penh (UTC+7) would open the form and see their 6am race listed as
 * 11pm the previous day, then save that wrong value back.
 */
function toDateTimeLocal(iso: string | null | undefined): string {
  if (!iso) return "";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";

  const pad = (n: number) => String(n).padStart(2, "0");
  return (
    `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}` +
    `T${pad(d.getHours())}:${pad(d.getMinutes())}`
  );
}

/** Dollars (as typed) → integer cents, the only form the API accepts. */
function toCents(value: string): number {
  const parsed = Number.parseFloat(value);
  if (Number.isNaN(parsed) || parsed < 0) return 0;
  return Math.round(parsed * 100);
}

/** An existing event type carries its `id` (so a save can PATCH it in place
 * rather than creating a duplicate); a freshly-added row (via
 * EventTypeBuilder's own "Add type" button) has none yet — see
 * EventUpdateRequestSchema's event_types_attributes, which treats a missing
 * `id` as "create new". */
type EditableEventType = ApiEventTypeDraft & { id?: string };

function toEditableTypes(types: ApiEvent["event_types"]): EditableEventType[] {
  return types.map((t, i) => ({
    id: t.id,
    name: t.name,
    description: t.description ?? undefined,
    capacity: t.capacity,
    price_cents: t.price_cents,
    position: i,
  }));
}

export function EventDetailsEditor({
  event,
  registeredCount = 0,
}: {
  event: ApiEvent;
  /**
   * Count of active (non-cancelled) registrations, passed down from
   * ManageEvent's already-loaded participants list. Purely informational —
   * lets the price field tell the organizer how many people are already
   * grandfathered in before they save a change. See
   * change-event-plan-tickets.md's "Ticket B": amount_owed_cents is
   * snapshotted per-registration server-side, so this is just messaging,
   * not something the frontend needs to enforce.
   */
  registeredCount?: number;
}) {
  const { t } = useTranslation();
  const queryClient = useQueryClient();

  const [title, setTitle] = useState(event.title);
  const [description, setDescription] = useState(event.description ?? "");
  const [category, setCategory] = useState(event.category);
  const [location, setLocation] = useState(event.location ?? "");
  const [routeMapUrl, setRouteMapUrl] = useState(event.route_map_url ?? "");
  const [startAt, setStartAt] = useState(toDateTimeLocal(event.start_at));
  const [endAt, setEndAt] = useState(toDateTimeLocal(event.end_at));
  // Same on/off toggle as the create form (events.new.tsx) — the price
  // field only makes sense to show once "paid" is selected, same reasoning
  // there: showing an always-visible $0 price input for a free event reads
  // as "this event costs $0" rather than "this event has no price at all".
  const [isPaid, setIsPaid] = useState(event.price_cents > 0);
  const [price, setPrice] = useState(
    event.price_cents ? (event.price_cents / 100).toFixed(2) : "",
  );

  // Event types (5K/10K-style sub-races) — same on/off toggle + builder as
  // the create form (events.new.tsx), just seeded from the event's existing
  // types instead of starting blank.
  const [hasEventTypes, setHasEventTypes] = useState(event.event_types.length > 0);
  const [types, setTypes] = useState<EditableEventType[]>(
    event.event_types.length > 0 ? toEditableTypes(event.event_types) : [newEventType(0)],
  );
  // Ids the organizer removed this session — EventTypeBuilder's own "remove"
  // button just drops a row from the array, which for a brand-new (id-less)
  // row is enough, but an *existing* type has to be sent back as
  // `{ id, _destroy: true }` or the backend has no way to know it should be
  // deleted rather than simply left untouched (a partial-update PATCH never
  // deletes a nested record it wasn't told about).
  const [removedTypeIds, setRemovedTypeIds] = useState<string[]>([]);

  function handleTypesChange(next: EditableEventType[]) {
    if (next.length < types.length) {
      const removed = types.find((t) => !next.includes(t));
      if (removed?.id) setRemovedTypeIds((prev) => [...prev, removed.id!]);
    }
    setTypes(next);
  }

  // Re-sync when the underlying event changes (e.g. after publishing, which
  // refetches the event). Without this the form would keep showing whatever
  // was in state when it first mounted.
  useEffect(() => {
    setTitle(event.title);
    setDescription(event.description ?? "");
    setCategory(event.category);
    setLocation(event.location ?? "");
    setRouteMapUrl(event.route_map_url ?? "");
    setStartAt(toDateTimeLocal(event.start_at));
    setEndAt(toDateTimeLocal(event.end_at));
    setIsPaid(event.price_cents > 0);
    setPrice(event.price_cents ? (event.price_cents / 100).toFixed(2) : "");
    setHasEventTypes(event.event_types.length > 0);
    setTypes(event.event_types.length > 0 ? toEditableTypes(event.event_types) : [newEventType(0)]);
    setRemovedTypeIds([]);
  }, [event]);

  // Client-side mirrors of the two model validations most likely to be hit, so
  // the organizer gets immediate feedback. The model remains the real
  // enforcement (Event#end_after_start, title presence/length) — this only
  // saves a round-trip, it isn't the check that matters.
  const trimmedTitle = title.trim();
  const titleError =
    trimmedTitle.length === 0
      ? t("eventForm.errors.titleRequired")
      : trimmedTitle.length > 120
        ? t("eventForm.errors.titleTooLong")
        : null;
  const dateError =
    startAt && endAt && new Date(endAt) <= new Date(startAt)
      ? t("eventForm.errors.endBeforeStart")
      : null;
  const canSave = !titleError && !dateError && Boolean(startAt);

  const save = useMutation({
    mutationFn: () => {
      // Turning the toggle off deletes every existing type outright (using
      // event.event_types, the server's last-known set — not the possibly
      // already-edited `types` state) — same "off means none" semantics as
      // the paid/free toggle above deleting the price.
      const eventTypesAttrs = hasEventTypes
        ? [
            ...types.filter((t) => t.name.trim()).map((t, i) => ({ ...t, position: i })),
            ...removedTypeIds.map((id) => ({ id, _destroy: true as const })),
          ]
        : event.event_types.map((t) => ({ id: t.id, _destroy: true as const }));

      return eventsApi.update(event.id, {
        title: trimmedTitle,
        description: description.trim() || null,
        category,
        location: location.trim() || null,
        route_map_url: routeMapUrl.trim() || null,
        // datetime-local gives a local wall-clock string with no zone; new Date
        // interprets it in the browser's zone, and toISOString converts to the
        // UTC the API stores.
        start_at: new Date(startAt).toISOString(),
        end_at: endAt ? new Date(endAt).toISOString() : null,
        price_cents: isPaid ? toCents(price) : 0,
        event_types_attributes: eventTypesAttrs,
      });
    },
    onSuccess: () => {
      // Both the organizer's view and the public event page show these fields.
      queryClient.invalidateQueries({ queryKey: ["event", event.id] });
      queryClient.invalidateQueries({ queryKey: ["public-event", event.id] });
      queryClient.invalidateQueries({ queryKey: ["my-events"] });
      // A price/date change may have just been logged — see
      // Api::V1::EventsController#log_event_details_changes.
      queryClient.invalidateQueries({ queryKey: ["event-activity", event.id] });
      toast.success(t("manageEvent.toastDetailsSaved"));
    },
    onError: (e: Error) => toast.error(e.message),
  });

  return (
    <div className="rounded-2xl border border-border bg-card p-6 space-y-5">
      <div>
        <h2 className="font-semibold">{t("manageEvent.detailsTitle")}</h2>
        <p className="text-sm text-muted-foreground">{t("manageEvent.detailsDesc")}</p>
      </div>

      <div className="space-y-2">
        <Label htmlFor="edit-title">{t("eventForm.title")}</Label>
        <Input
          id="edit-title"
          value={title}
          onChange={(e) => setTitle(e.target.value)}
          aria-invalid={Boolean(titleError)}
        />
        {titleError && <p className="text-sm text-destructive">{titleError}</p>}
      </div>

      <div className="space-y-2">
        <Label htmlFor="edit-description">{t("eventForm.description")}</Label>
        <Textarea
          id="edit-description"
          value={description}
          onChange={(e) => setDescription(e.target.value)}
          rows={4}
        />
      </div>

      <div className="space-y-2">
        <Label htmlFor="edit-category">{t("eventForm.category")}</Label>
        <Select value={category} onValueChange={setCategory}>
          <SelectTrigger id="edit-category">
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            {eventCategoryOptions().map((option) => (
              <SelectItem key={option.value} value={option.value}>
                {option.label}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </div>

      <div className="space-y-2">
        <Label htmlFor="edit-location">{t("eventForm.location")}</Label>
        {/* Plain text input, not the LocationPicker used on the create form:
            editing the text here leaves latitude/longitude untouched, so an
            existing map pin is preserved rather than being wiped by a typo
            fix. Re-pinning on the map is a separate concern. */}
        <Input
          id="edit-location"
          value={location}
          onChange={(e) => setLocation(e.target.value)}
        />
        {event.latitude != null && event.longitude != null && (
          <p className="text-xs text-muted-foreground">{t("manageEvent.mapPinPreserved")}</p>
        )}
      </div>

      <div className="space-y-2">
        <Label htmlFor="edit-route-map">{t("eventForm.routeMapUrl")}</Label>
        <Input
          id="edit-route-map"
          type="url"
          value={routeMapUrl}
          onChange={(e) => setRouteMapUrl(e.target.value)}
          placeholder={t("eventForm.routeMapUrlPlaceholder")}
        />
      </div>

      <div className="grid gap-5 sm:grid-cols-2">
        <div className="space-y-2">
          <Label htmlFor="edit-start">{t("eventForm.starts")}</Label>
          <Input
            id="edit-start"
            type="datetime-local"
            value={startAt}
            onChange={(e) => setStartAt(e.target.value)}
          />
        </div>
        <div className="space-y-2">
          <Label htmlFor="edit-end">{t("eventForm.endsOptional")}</Label>
          <Input
            id="edit-end"
            type="datetime-local"
            value={endAt}
            onChange={(e) => setEndAt(e.target.value)}
            aria-invalid={Boolean(dateError)}
          />
        </div>
      </div>
      {dateError && <p className="text-sm text-destructive">{dateError}</p>}

      <div className="flex items-center justify-between rounded-xl border border-border p-4">
        <div>
          <p className="font-medium">{t("eventForm.paidEvent")}</p>
          <p className="text-sm text-muted-foreground">{t("eventForm.paidEventDesc")}</p>
        </div>
        <Switch checked={isPaid} onCheckedChange={setIsPaid} />
      </div>

      {isPaid && (
        <div className="space-y-2">
          <Label htmlFor="edit-price">{t("eventForm.price")}</Label>
          <Input
            id="edit-price"
            type="number"
            min="0"
            step="1"
            value={price}
            onChange={(e) => setPrice(e.target.value)}
            placeholder={t("eventForm.pricePlaceholder")}
          />
          <p className="text-xs text-muted-foreground">
            {registeredCount > 0
              ? t("manageEvent.priceChangeHintWithCount", { count: registeredCount })
              : t("manageEvent.priceChangeHint")}
          </p>
        </div>
      )}

      <div className="rounded-xl border border-border p-4 space-y-4">
        <div className="flex items-center justify-between">
          <div>
            <p className="font-medium">{t("eventForm.eventTypesTitle")}</p>
            <p className="text-sm text-muted-foreground">{t("eventForm.eventTypesDesc")}</p>
          </div>
          <Switch checked={hasEventTypes} onCheckedChange={setHasEventTypes} />
        </div>

        {hasEventTypes && (
          <EventTypeBuilder
            types={types}
            onTypesChange={handleTypesChange}
            eventPriceCents={isPaid ? toCents(price) : 0}
          />
        )}
      </div>

      <Button onClick={() => save.mutate()} disabled={!canSave || save.isPending} className="gap-2">
        {save.isPending && <Loader2 className="h-4 w-4 animate-spin" />}
        {t("manageEvent.saveDetails")}
      </Button>
    </div>
  );
}
