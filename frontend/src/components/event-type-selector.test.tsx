import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";

import i18n from "@/lib/i18n";
import { EventTypeSelector } from "@/components/event-type-selector";
import type { ApiEventType } from "@/lib/api-client";

/**
 * Covers the participant-facing capacity rules, which are the part of this
 * component with real consequences: a full event type must not be selectable,
 * and the running total has to fall back to the event's base price when a type
 * has no price of its own (mirroring EventType#effective_price_cents on the
 * backend).
 */

function eventType(overrides: Partial<ApiEventType> = {}): ApiEventType {
  return {
    id: "type-1",
    event_id: "event-1",
    name: "5K",
    description: null,
    capacity: null,
    price_cents: null,
    position: 0,
    spots_remaining: null,
    ...overrides,
  } as ApiEventType;
}

function renderSelector(props: Partial<React.ComponentProps<typeof EventTypeSelector>> = {}) {
  const onToggle = vi.fn();
  const onNext = vi.fn();
  const onBack = vi.fn();

  render(
    <EventTypeSelector
      eventTypes={[eventType()]}
      eventPriceCents={0}
      currency="usd"
      selectedIds={[]}
      onToggle={onToggle}
      onNext={onNext}
      onBack={onBack}
      brandColor="#6366f1"
      isPending={false}
      {...props}
    />,
  );

  return { onToggle, onNext, onBack };
}

describe("EventTypeSelector", () => {
  beforeEach(async () => {
    await i18n.changeLanguage("en");
  });

  it("renders each event type by name", () => {
    renderSelector({
      eventTypes: [
        eventType({ id: "t1", name: "5K" }),
        eventType({ id: "t2", name: "10K", position: 1 }),
      ],
    });

    expect(screen.getByText("5K")).toBeInTheDocument();
    expect(screen.getByText("10K")).toBeInTheDocument();
  });

  it("calls onToggle with the type id when an available type is clicked", async () => {
    const user = userEvent.setup();
    const { onToggle } = renderSelector({
      eventTypes: [eventType({ id: "t1", name: "5K", spots_remaining: 5 })],
    });

    await user.click(screen.getByRole("checkbox"));

    expect(onToggle).toHaveBeenCalledWith("t1");
  });

  it("disables a full type and does not call onToggle when it is clicked", async () => {
    const user = userEvent.setup();
    const { onToggle } = renderSelector({
      eventTypes: [eventType({ id: "t1", name: "5K", capacity: 10, spots_remaining: 0 })],
    });

    const checkbox = screen.getByRole("checkbox");
    expect(checkbox).toBeDisabled();

    await user.click(checkbox);

    expect(onToggle).not.toHaveBeenCalled();
  });

  it("treats spots_remaining of null as unlimited, not as full", () => {
    renderSelector({
      eventTypes: [eventType({ id: "t1", name: "5K", capacity: null, spots_remaining: null })],
    });

    // The distinction matters: `null` means no capacity limit, `0` means full.
    // Reading null as falsy here would wrongly lock an uncapped type.
    expect(screen.getByRole("checkbox")).not.toBeDisabled();
    expect(screen.queryByText(i18n.t("eventDetail.full"))).not.toBeInTheDocument();
  });

  it("falls back to the event base price for a type with no price of its own", () => {
    renderSelector({
      eventTypes: [eventType({ id: "t1", name: "5K", price_cents: null })],
      eventPriceCents: 2500,
      // Deliberately left unselected: with a selection the total row would
      // also render $25.00 and the query below would be ambiguous.
      selectedIds: [],
    });

    // 2500 cents = $25.00, taken from the event since the type's price is null.
    expect(screen.getByText("$25.00")).toBeInTheDocument();
  });

  it("sums the selected types' prices into the total", () => {
    renderSelector({
      eventTypes: [
        eventType({ id: "t1", name: "5K", price_cents: 1000 }),
        eventType({ id: "t2", name: "10K", price_cents: 1500, position: 1 }),
      ],
      eventPriceCents: 0,
      selectedIds: ["t1", "t2"],
    });

    // $10 + $15 = $25 total.
    expect(screen.getByText(/25/)).toBeInTheDocument();
  });

  it("disables the next button until at least one type is selected", () => {
    const { onNext } = renderSelector({ selectedIds: [] });

    const next = screen.getByRole("button", { name: i18n.t("eventTypeSelector.next") });
    expect(next).toBeDisabled();
    expect(onNext).not.toHaveBeenCalled();
  });

  it("enables the next button and calls onNext once a type is selected", async () => {
    const user = userEvent.setup();
    const { onNext } = renderSelector({
      eventTypes: [eventType({ id: "t1" })],
      selectedIds: ["t1"],
    });

    const next = screen.getByRole("button", { name: i18n.t("eventTypeSelector.next") });
    expect(next).toBeEnabled();

    await user.click(next);

    expect(onNext).toHaveBeenCalled();
  });

  it("keeps the next button disabled while a registration is in flight", () => {
    renderSelector({ selectedIds: ["type-1"], isPending: true });

    // Guards against double-submitting a registration: a type is selected, so
    // the only thing keeping the button disabled is isPending.
    expect(screen.getByRole("button", { name: i18n.t("eventTypeSelector.next") })).toBeDisabled();
  });

  it("uses a custom next label when given one", () => {
    renderSelector({ selectedIds: ["type-1"], nextLabel: "Register now" });

    expect(screen.getByRole("button", { name: "Register now" })).toBeInTheDocument();
  });
});
