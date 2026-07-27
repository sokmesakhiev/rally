import i18n from "@/lib/i18n";

export function formatPrice(cents: number, currency = "usd"): string {
  if (!cents) return i18n.t("common.free");
  return new Intl.NumberFormat(i18n.language, {
    style: "currency",
    currency: currency.toUpperCase(),
  }).format(cents / 100);
}

export function formatDateTime(iso: string): string {
  return new Date(iso).toLocaleString(i18n.language, {
    weekday: "short",
    month: "short",
    day: "numeric",
    year: "numeric",
    hour: "numeric",
    minute: "2-digit",
  });
}

export function formatDate(iso: string): string {
  return new Date(iso).toLocaleDateString(i18n.language, {
    month: "short",
    day: "numeric",
    year: "numeric",
  });
}

export const EVENT_CATEGORY_VALUES = [
  "running",
  "cycling",
  "swimming",
  "triathlon",
  "hiking",
  "other",
] as const;

export type EventCategoryValue = (typeof EVENT_CATEGORY_VALUES)[number];

/** Translated {value, label} pairs for rendering a category picker. Call
 * this inside a component render (not at module scope) so it re-computes
 * when the language changes. */
export function eventCategoryOptions(): { value: EventCategoryValue; label: string }[] {
  return EVENT_CATEGORY_VALUES.map((value) => ({
    value,
    label: i18n.t(`eventCategories.${value}`),
  }));
}

export function categoryLabel(value: string): string {
  if ((EVENT_CATEGORY_VALUES as readonly string[]).includes(value)) {
    return i18n.t(`eventCategories.${value}`);
  }
  return i18n.t("eventCategories.event");
}

/** A plain "View on map" link — works with no Google Maps API key, since
 * it just opens Google Maps in a new tab rather than embedding anything. */
export function googleMapsViewUrl(latitude: number, longitude: number): string {
  return `https://www.google.com/maps?q=${latitude},${longitude}`;
}
