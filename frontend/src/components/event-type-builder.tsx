/**
 * EventTypeBuilder — lets event hosts define registration tiers/distances.
 * e.g. 3km ($10), 5km ($15), 10km ($20), Half Marathon ($35), Full Marathon ($50)
 */
import { Trash2, Plus, GripVertical } from "lucide-react";
import { useTranslation } from "react-i18next";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import type { ApiEventTypeDraft } from "@/lib/api-client";

// ── Helpers ───────────────────────────────────────────────────────────────────

export function newEventType(position: number): ApiEventTypeDraft {
  return { name: "", description: "", capacity: null, price_cents: null, position };
}

// ── Row component ─────────────────────────────────────────────────────────────

function TypeRow({
  type,
  index,
  eventPriceCents,
  allowPricing,
  onChange,
  onRemove,
  removable,
}: {
  type: ApiEventTypeDraft;
  index: number;
  eventPriceCents: number;
  allowPricing: boolean;
  onChange: (t: ApiEventTypeDraft) => void;
  onRemove: () => void;
  removable: boolean;
}) {
  const { t } = useTranslation();
  function set<K extends keyof ApiEventTypeDraft>(key: K, value: ApiEventTypeDraft[K]) {
    onChange({ ...type, [key]: value });
  }

  const priceDisplay = type.price_cents != null ? (type.price_cents / 100).toFixed(2) : "";

  const capacityDisplay = type.capacity != null ? String(type.capacity) : "";

  return (
    <div className="rounded-xl border border-border bg-card p-4 space-y-3">
      {/* Header */}
      <div className="flex items-center justify-between gap-2">
        <div className="flex items-center gap-2 text-muted-foreground">
          <GripVertical className="h-4 w-4 flex-shrink-0" />
          <span className="text-xs font-medium uppercase tracking-wide">
            {t("eventTypeBuilder.typeLabel", { number: index + 1 })}
          </span>
        </div>
        {removable && (
          <button
            type="button"
            onClick={onRemove}
            className="text-muted-foreground hover:text-destructive"
          >
            <Trash2 className="h-4 w-4" />
          </button>
        )}
      </div>

      {/* Name */}
      <div className="space-y-1.5">
        <Label className="text-xs">
          {t("eventTypeBuilder.name")} <span className="text-destructive">*</span>
        </Label>
        <Input
          value={type.name}
          onChange={(e) => set("name", e.target.value)}
          placeholder={t("eventTypeBuilder.namePlaceholder")}
          maxLength={120}
        />
      </div>

      {/* Description */}
      <div className="space-y-1.5">
        <Label className="text-xs">{t("eventTypeBuilder.descriptionOptional")}</Label>
        <Textarea
          value={type.description ?? ""}
          onChange={(e) => set("description", e.target.value || undefined)}
          placeholder={t("eventTypeBuilder.descriptionPlaceholder")}
          rows={2}
          className="resize-none text-sm"
        />
      </div>

      {/* Price + Capacity row */}
      <div className={allowPricing ? "grid grid-cols-2 gap-3" : "grid grid-cols-1 gap-3"}>
        {/* Hidden entirely for unverified organizers — a per-type price is
            just as much a "paid event" as an event-level one, and the server
            rejects it identically (Event#paid? checks both). Showing the
            field would only invite filling it in and getting bounced. */}
        {allowPricing && (
          <div className="space-y-1.5">
            <Label className="text-xs">{t("eventForm.price")}</Label>
            <Input
              type="number"
              min="0"
              step="1"
              value={priceDisplay}
              onChange={(e) => {
                const val = e.target.value;
                set("price_cents", val === "" ? null : Math.round(Number(val) * 100));
              }}
              placeholder={t("eventTypeBuilder.defaultPrice", {
                price: (eventPriceCents / 100).toFixed(2),
              })}
              className="h-8 text-sm"
            />
            {type.price_cents == null && (
              <p className="text-[11px] text-muted-foreground">
                {t("eventTypeBuilder.usesEventPrice")}
              </p>
            )}
          </div>
        )}

        <div className="space-y-1.5">
          <Label className="text-xs">{t("eventTypeBuilder.capacity")}</Label>
          <Input
            type="number"
            min="1"
            value={capacityDisplay}
            onChange={(e) => {
              const val = e.target.value;
              set("capacity", val === "" ? null : Number(val));
            }}
            placeholder={t("eventTypeBuilder.unlimited")}
            className="h-8 text-sm"
          />
        </div>
      </div>
    </div>
  );
}

// ── Main component ────────────────────────────────────────────────────────────

interface EventTypeBuilderProps {
  types: ApiEventTypeDraft[];
  onTypesChange: (types: ApiEventTypeDraft[]) => void;
  /** Used to display the fallback price in the per-type price placeholder */
  eventPriceCents: number;
  /**
   * Whether to show the per-type price field at all. False for organizers
   * who aren't verified to create paid events — see PaidEventGate and
   * Api::V1::EventsController#reject_unverified_paid_event!, which rejects
   * per-type prices exactly as it does event-level ones. UI affordance only;
   * the server is the real check.
   */
  allowPricing?: boolean;
}

export function EventTypeBuilder({
  types,
  onTypesChange,
  eventPriceCents,
  allowPricing = true,
}: EventTypeBuilderProps) {
  const { t } = useTranslation();
  function addType() {
    onTypesChange([...types, newEventType(types.length)]);
  }

  function updateType(index: number, t: ApiEventTypeDraft) {
    onTypesChange(types.map((existing, i) => (i === index ? t : existing)));
  }

  function removeType(index: number) {
    onTypesChange(types.filter((_, i) => i !== index).map((t, i) => ({ ...t, position: i })));
  }

  return (
    <div className="space-y-3">
      {types.map((t, i) => (
        <TypeRow
          key={i}
          index={i}
          type={t}
          eventPriceCents={eventPriceCents}
          allowPricing={allowPricing}
          onChange={(updated) => updateType(i, updated)}
          onRemove={() => removeType(i)}
          removable={types.length > 1}
        />
      ))}

      <Button type="button" variant="outline" size="sm" className="gap-1.5" onClick={addType}>
        <Plus className="h-4 w-4" /> {t("eventTypeBuilder.addType")}
      </Button>
    </div>
  );
}
