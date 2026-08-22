# Change event plan — tickets

Scoped 2026-08-21 after reviewing the request against the current codebase. Confirmed gap:
`EventPlanPaymentsController#create` explicitly refuses to run once `event.is_published?` is
true, and the frontend's plan picker only renders `{!ev.is_published && (...)}` — there is no
path, front or back, to change plan after publishing today.

Per discussion, the four original criteria split into two related but separate features:
"plan" (`Event::PLANS`) is the organizer-to-Rally capacity-tier fee; the event's own
attendee-facing ticket price (`Event#price_cents` / `EventType#price_cents`) is a different,
already-independently-editable field. Criteria 1–2 govern the former, 3–4 the latter.

---

## Ticket A — Change Rally plan tier after publishing

**Status:** Done (2026-08-21).

**Priority:** High — this is the core "we don't have this option" gap as reported.

**Problem**
Once `EventPlanPayment#mark_paid!` has published an event under a plan, there is no way to
move it to a different plan. `EventPlanPaymentsController#create` is publish-only (rejects
already-published events); nothing else touches `event.plan`/`event.capacity` after that.

**Rules to implement** (from criteria 1–2):
1. Upgrading to a bigger plan charges the **prorated difference** — `new_plan_price -
   amount_already_paid_for_this_event's_plan`, not the new tier's full price again.
2. Downgrading to a smaller plan is free (no charge) and **issues no refund** for the
   difference already paid.

**Proposed scope**
- New controller action — either a new `PATCH /api/v1/events/:id/plan` or extending
  `EventPlanPaymentsController#create` to branch on `is_published?` instead of rejecting it —
  handling both directions:
  - **Upgrade**: compute `amount_already_paid` as the sum of `paid` `EventPlanPayment` rows
    for this event (not a flat lookup of `Event::PLANS[event.plan][:price_cents]` — see open
    question below on repeated tier changes). Charge the difference via the same ABA PayWay
    QR flow `#create` already uses for the initial publish. On confirmed payment, update
    `event.plan`/`event.capacity` the same way `EventPlanPayment#mark_paid!` does today.
  - **Downgrade**: no payment step. Still worth recording an `EventPlanPayment` row with
    `amount_cents: 0` and `status: "paid"` purely for audit history (so "what plan was this
    event on, and when" stays reconstructable), then update `event.plan`/`event.capacity`
    directly.
- **New capacity guard, independent of the existing one.** `Event#capacity_covers_event_types`
  today only checks the new plan's capacity against the event's *type* limits
  (`combined_event_type_capacity`) — it has no idea how many people are actually registered.
  Downgrading needs a second check: `new_plan.capacity >= event.registrations.active.count`.
  Without it, an organizer could downgrade a 150-person event down to the 20-person free tier
  with no error, silently leaving the event over its own stated capacity.
- Reuse the existing pending/expired/declined `EventPlanPayment` status machinery for the
  upgrade payment attempt — same 15-minute expiry pattern `#create` already uses.
- Frontend: surface a "change plan" action on the manage-event page for published events
  (today the whole plan section is gated behind `!ev.is_published`), showing the prorated
  price for each available upgrade and a plain "no refund" notice on downgrade options.

**Open questions**
- **Repeated changes.** If an organizer upgrades, then downgrades, then upgrades back to a
  plan they'd already once paid for, do they pay again? Summing all `paid` `EventPlanPayment`
  rows (as proposed above) means no — the delta from a plan they've already fully paid for
  would compute to zero or negative (floor at zero). Confirm that's the intended behavior
  before building it, since "pay again" is an equally defensible reading of "no refund" cutting
  both ways.
- Whether a *pending* (unconfirmed) upgrade should block starting another plan change, the
  same way `EventPlanPaymentsController` doesn't currently guard against concurrent attempts
  either.

---

## Ticket B — Grandfather attendee pricing when it changes on a published event

**Status:** Done (2026-08-21).

**Priority:** High — closes a real, currently-accidental gap, and fixes a related live bug
found while reviewing it (see below).

**Problem**
`EventsController#update` already lets an organizer edit `price_cents` (and each
`EventType#price_cents`) on a published event today, with zero rules around existing
registrants — criteria 3–4 aren't describing new capability so much as a currently
*unspecified* one.

The good news: existing **paid** registrations are already safe by accident.
`payment_status` is locked to `"paid"` the moment a free registration is created, and
`Payments::CreatePayment#call` checks `registration.payment_status == "paid"` *before* it
recomputes anything owed — so a past free registrant can't be charged just because the price
changed later.

**The bad news, found during this review — a related pre-existing bug**: `Registration
#owed_amount_cents` always recomputes *live* from the event/event-type's *current*
`price_cents`, rather than from what was true at registration time. That's harmless for a
`payment_status: "paid"` registration (nothing calls `owed_amount_cents` for those in a
money-moving path), but a registration that's still **`unpaid`** — someone registered for a
paid event and hasn't completed the ABA KHQR step yet — has no such protection. If the
organizer changes the price while that payment is outstanding, the *next* poll/payment
attempt charges the *new* price, silently, with nothing telling the participant it changed
from what they saw at registration.

**Rules to implement** (from criteria 3–4):
3. Free → paid: existing (already-`paid`) registrations stay exempt; only new registrants pay.
4. Paid → free: no refund is issued for existing paid registrations.

**Proposed scope**
- **Snapshot the price at registration time** instead of recomputing it live — add
  `amount_owed_cents` (or similar) to `Registration`, set once in
  `RegistrationsController#create` from `compute_amount`, and have `Payments::CreatePayment`
  and anywhere else that needs "what does this registration owe" read that column instead of
  calling the live `owed_amount_cents`. This single change both formalizes criterion 3
  (nothing to grandfather-guard against, since the number literally can't drift) and fixes the
  outstanding-payment bug above as a side effect.
- Criterion 4 needs no new mechanism — not issuing a refund is already the default behavior
  (nothing today triggers one on a price drop); this is really just confirming that's the
  intended, permanent behavior rather than a gap to fill.
- Frontend: the manage-event price-edit field currently has no messaging about how a change
  affects existing registrants — worth a confirmation step ("N people already registered at
  the old price and won't be affected") when editing price on a published event with existing
  registrations.

**Open questions**
- Does this rule apply the same way to per-`EventType` price changes as to the flat
  `Event#price_cents`? The reasoning is identical, but worth confirming both are in scope
  together rather than assuming. **Resolved during implementation:** yes — the snapshot is
  taken from `compute_amount`, which already sums selected event types' `effective_price_cents`
  (falling back to the flat event price only when no types were selected), so both paths are
  covered by the same mechanism with no special-casing.
- Should organizers be able to see, per-registration, what price each participant actually
  locked in — useful for support/dispute questions ("why did I pay less than the listed
  price")? Not required for the core rule, but a natural follow-up once the data exists.
  **Not built** — `amount_owed_cents` isn't yet exposed in `registration_json`; left as a
  follow-up since it wasn't needed for the core fix.

**Implementation notes (2026-08-21)**
- Backend: `add_amount_owed_cents_to_registrations` migration adds a nullable
  `registrations.amount_owed_cents` integer column. `Registration#owed_amount_cents` now
  returns the snapshot when present, falling back to the old live recompute
  (`live_owed_amount_cents`, private) only for pre-existing rows that predate the column —
  no backfill migration, since there's nothing to backfill from (the price at creation time for
  old rows isn't recorded anywhere).
- Both registration-creation paths — `Api::V1::RegistrationsController#create` and
  `Waitlists::PromoteNext#promote!` — already computed `amount` before creating the row; both
  now also pass it as `amount_owed_cents:`. `Payments::CreatePayment` and
  `RegistrationMailer` needed no changes at all, since they already read through
  `registration.owed_amount_cents`, which now transparently prefers the snapshot.
- Criterion 4 (paid → free, no refund) confirmed as already-correct existing behavior, no code
  change — nothing in the codebase triggers a refund on a price drop today.
- Frontend: `EventDetailsEditor` takes a new `registeredCount` prop (passed from
  `ManageEvent`'s already-loaded `participants.length`) and shows a dynamic
  `manageEvent.priceChangeHintWithCount` message ("N people already registered at the old
  price and won't be affected") under the price field whenever the event has at least one
  registrant, replacing the generic static hint in that case.
- Specs: `spec/models/registration_spec.rb` (new) covers the snapshot/fallback/legacy-row
  behavior directly; `spec/services/payments/create_payment_spec.rb` gained a regression test
  charging the snapshotted amount after the event's price changed; `spec/requests/
  registrations_spec.rb` and `spec/services/waitlists/promote_next_spec.rb` both gained
  coverage that the snapshot is actually set on creation/promotion. All new/changed Ruby files
  passed `ruby -c`; `bundle exec rspec` still needs to run locally to confirm (no working
  Ruby/bundler toolchain in this sandbox).
