import { describe, it, expect, beforeEach } from "vitest";

import i18n from "@/lib/i18n";
import {
  formatPrice,
  categoryLabel,
  eventCategoryOptions,
  googleMapsViewUrl,
  EVENT_CATEGORY_VALUES,
} from "@/lib/event-utils";

describe("event-utils", () => {
  beforeEach(async () => {
    // i18n boots to English (see lib/i18n.ts — deliberate, to keep SSR and
    // the client's first render identical). Reset explicitly so a test that
    // switches language can't leak into the next one.
    await i18n.changeLanguage("en");
  });

  describe("formatPrice", () => {
    it("renders 0 cents as the translated 'free' label rather than $0.00", () => {
      expect(formatPrice(0)).toBe(i18n.t("common.free"));
    });

    it("treats a missing/NaN-ish price as free too", () => {
      // formatPrice guards with `if (!cents)`, so these all take the free path
      // — worth pinning, since an event with no price set is the common case.
      expect(formatPrice(undefined as unknown as number)).toBe(i18n.t("common.free"));
    });

    it("formats cents as a currency amount, not raw cents", () => {
      const result = formatPrice(2500, "usd");

      expect(result).toContain("25");
      expect(result).not.toContain("2500");
    });

    it("respects the currency argument", () => {
      // KHR and USD should not render identically — this is the bug that
      // would silently show Cambodian riel amounts as dollars.
      expect(formatPrice(2500, "khr")).not.toBe(formatPrice(2500, "usd"));
    });

    it("defaults to usd when no currency is given", () => {
      expect(formatPrice(2500)).toBe(formatPrice(2500, "usd"));
    });
  });

  describe("categoryLabel", () => {
    it("returns a translated label for every known category", () => {
      for (const value of EVENT_CATEGORY_VALUES) {
        const label = categoryLabel(value);

        expect(label).toBeTruthy();
        // A missing translation would fall through to the raw key.
        expect(label).not.toBe(`eventCategories.${value}`);
      }
    });

    it("falls back to a generic label for an unknown category", () => {
      expect(categoryLabel("underwater-basketweaving")).toBe(i18n.t("eventCategories.event"));
    });
  });

  describe("eventCategoryOptions", () => {
    it("returns one option per category value, in order", () => {
      const options = eventCategoryOptions();

      expect(options.map((o) => o.value)).toEqual([...EVENT_CATEGORY_VALUES]);
      expect(options.every((o) => Boolean(o.label))).toBe(true);
    });

    it("re-evaluates labels after a language change", async () => {
      // This is the reason it's a function and not the old EVENT_CATEGORIES
      // constant — a module-scope constant would keep English labels forever
      // after switching to Khmer.
      const english = eventCategoryOptions();
      await i18n.changeLanguage("km");
      const khmer = eventCategoryOptions();

      expect(khmer.map((o) => o.value)).toEqual(english.map((o) => o.value));
      expect(khmer.map((o) => o.label)).not.toEqual(english.map((o) => o.label));
    });
  });

  describe("googleMapsViewUrl", () => {
    it("builds a plain maps query URL with no API key in it", () => {
      const url = googleMapsViewUrl(11.5564, 104.9282);

      expect(url).toBe("https://www.google.com/maps?q=11.5564,104.9282");
      expect(url).not.toMatch(/key=/);
    });

    it("handles negative coordinates", () => {
      expect(googleMapsViewUrl(-33.8688, -151.2093)).toBe(
        "https://www.google.com/maps?q=-33.8688,-151.2093",
      );
    });
  });
});
