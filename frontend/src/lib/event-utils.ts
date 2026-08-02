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

/** Renders a finish time as "H:MM:SS" (or "MM:SS" under an hour) — mirrors
 * what Result.parse_duration_to_seconds on the backend accepts, so a value
 * round-trips through the input unchanged. */
export function formatFinishTime(totalSeconds: number): string {
  const hours = Math.floor(totalSeconds / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  const seconds = Math.floor(totalSeconds % 60);
  const pad = (n: number) => String(n).padStart(2, "0");

  return hours > 0 ? `${hours}:${pad(minutes)}:${pad(seconds)}` : `${minutes}:${pad(seconds)}`;
}

/** Parses "H:MM:SS", "MM:SS", or a bare number of seconds into a total
 * seconds count. Returns null for anything else, so callers can show a
 * validation error instead of silently sending garbage. */
export function parseFinishTime(input: string): number | null {
  const value = input.trim();
  if (!value) return null;

  if (/^\d+$/.test(value)) return parseInt(value, 10);

  const parts = value.split(":").map((p) => p.trim());
  if (parts.length === 2 || parts.length === 3) {
    if (parts.some((p) => !/^\d{1,3}$/.test(p))) return null;
    const nums = parts.map((p) => parseInt(p, 10));
    if (nums.length === 3) {
      const [h, m, s] = nums;
      if (m > 59 || s > 59) return null;
      return h * 3600 + m * 60 + s;
    }
    const [m, s] = nums;
    if (s > 59) return null;
    return m * 60 + s;
  }

  return null;
}
