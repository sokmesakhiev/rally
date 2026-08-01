/**
 * EventTypeSelector — shown to participants during event registration
 * when the event offers multiple types/distances.
 * Supports multi-select (participants can register for more than one type).
 */
import { Loader2, Users } from "lucide-react";
import { useTranslation } from "react-i18next";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
import { Badge } from "@/components/ui/badge";
import { formatPrice } from "@/lib/event-utils";
import type { ApiEventType } from "@/lib/api-client";

interface EventTypeSelectorProps {
  eventTypes: ApiEventType[];
  /** Effective event base price, used when a type has no own price */
  eventPriceCents: number;
  currency: string;
  selectedIds: string[];
  onToggle: (id: string) => void;
  onNext: () => void;
  onBack: () => void;
  brandColor: string;
  isPending: boolean;
  /** Label for the "Next" button — "Register" if no survey follows, "Next" if survey follows */
  nextLabel?: string;
  /** Shown as a small link next to a full type — joins the waitlist for just that type. Omit to hide. */
  onJoinWaitlist?: (eventTypeId: string) => void;
  waitlistPendingTypeId?: string | null;
}

export function EventTypeSelector({
  eventTypes,
  eventPriceCents,
  currency,
  selectedIds,
  onToggle,
  onNext,
  onBack,
  brandColor,
  isPending,
  nextLabel,
  onJoinWaitlist,
  waitlistPendingTypeId,
}: EventTypeSelectorProps) {
  const { t } = useTranslation();
  const total = selectedIds.reduce((sum, id) => {
    const et = eventTypes.find((x) => x.id === id);
    if (!et) return sum;
    return sum + (et.price_cents ?? eventPriceCents);
  }, 0);

  const canProceed = selectedIds.length > 0;

  return (
    <div className="space-y-4">
      <div>
        <h3 className="font-semibold text-lg">{t("eventTypeSelector.title")}</h3>
        <p className="text-sm text-muted-foreground mt-0.5">{t("eventTypeSelector.subtitle")}</p>
      </div>

      <div className="space-y-2">
        {eventTypes.map((et) => {
          const selected = selectedIds.includes(et.id);
          const priceCents = et.price_cents ?? eventPriceCents;
          const isFull = et.spots_remaining !== null && et.spots_remaining === 0;

          return (
            <label
              key={et.id}
              className={`flex items-start gap-3 rounded-xl border p-4 cursor-pointer transition-colors ${
                isFull
                  ? "opacity-50 cursor-not-allowed border-border"
                  : selected
                    ? "border-[var(--brand)]"
                    : "border-border hover:border-muted-foreground/40"
              }`}
              style={
                selected && !isFull
                  ? { borderColor: brandColor, backgroundColor: `${brandColor}0d` }
                  : {}
              }
            >
              <Checkbox
                id={`type-${et.id}`}
                checked={selected}
                disabled={isFull}
                onCheckedChange={() => !isFull && onToggle(et.id)}
                className="mt-0.5 flex-shrink-0"
              />
              <div className="flex-1 min-w-0">
                <div className="flex flex-wrap items-center gap-2">
                  <span className="font-medium">{et.name}</span>
                  <Badge variant="outline">{formatPrice(priceCents, currency)}</Badge>
                  {isFull && <Badge variant="secondary">{t("eventDetail.full")}</Badge>}
                  {isFull && onJoinWaitlist && (
                    <button
                      type="button"
                      onClick={(e) => {
                        e.preventDefault();
                        onJoinWaitlist(et.id);
                      }}
                      disabled={waitlistPendingTypeId === et.id}
                      className="text-xs underline underline-offset-2 text-muted-foreground hover:text-foreground disabled:opacity-50"
                    >
                      {t("eventTypeSelector.joinWaitlistForType")}
                    </button>
                  )}
                  {!isFull && et.spots_remaining !== null && (
                    <span className="text-xs text-muted-foreground flex items-center gap-1">
                      <Users className="h-3 w-3" />{" "}
                      {t("eventTypeSelector.spotsLeft", { count: et.spots_remaining })}
                    </span>
                  )}
                </div>
                {et.description && (
                  <p className="text-sm text-muted-foreground mt-0.5">{et.description}</p>
                )}
              </div>
            </label>
          );
        })}
      </div>

      {/* Total */}
      {selectedIds.length > 0 && (
        <div className="flex items-center justify-between rounded-lg bg-muted/50 px-4 py-2.5 text-sm">
          <span className="text-muted-foreground">
            {t("eventTypeSelector.typesSelected", { count: selectedIds.length })}
          </span>
          <span className="font-semibold">
            {t("eventTypeSelector.total", { amount: formatPrice(total, currency) })}
          </span>
        </div>
      )}

      <div className="flex gap-3 pt-1">
        <Button type="button" variant="outline" onClick={onBack}>
          {t("common.back")}
        </Button>
        <Button
          type="button"
          disabled={!canProceed || isPending}
          onClick={onNext}
          style={{ backgroundColor: brandColor }}
          className="flex-1 text-white hover:opacity-90 disabled:opacity-50"
        >
          {isPending && <Loader2 className="h-4 w-4 animate-spin" />}
          {nextLabel ?? t("eventTypeSelector.next")}
        </Button>
      </div>
    </div>
  );
}
