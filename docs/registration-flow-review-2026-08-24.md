# Registration process review — against the proposed flow

Reviewed 2026-08-24 against the current implementation (`frontend/src/routes/events.$eventId.tsx`,
`Registrations::GuestCheckout`, `Api::V1::RegistrationsController#create`).

## Your proposed flow, checked point by point

**Entry point** — scan QR → event detail page → tap Register.
**Already matches.** `EventQRCode` links to the plain event page, not straight into the form
(closed as intentional in the earlier registration-engagement review — most people want to see
what they're signing up for before committing). The Register button is what starts the flow
below.

**New user**

| Step | Your spec | Current behavior |
|---|---|---|
| 1 | Name, Email, or Phone | ✅ Matches. "Continue as guest" form collects name + at least one of email/phone. |
| 2 | Pick sub-type, if any | ✅ Matches. Shown next, only if the event has event types. |
| 3 | Survey, if configured | ✅ Matches. Shown after types, only if the event has a survey. |
| 4 | **Confirmation summary before payment, for paid events** | ❌ **Missing.** See gap below. |
| 5 | Non-refundable-for-mistakes notice | ❌ **Missing** — nowhere in the flow today. |

**Existing user**

| Scenario | Your spec | Current behavior |
|---|---|---|
| Not signed in | Same as new-user steps | ✅ Matches — there's no separate "returning guest" path; anyone without a session goes through the same guest form. (If the email/phone they type matches an existing account, the backend rejects with `email_registered`/`phone_registered` and the UI offers a "Sign in instead" action right there — see `GuestCheckout`.) |
| Signed in | Skip straight to event registration step | ✅ Matches exactly. `handleRegisterClick` checks `user` and calls `advancePastGuestStep()` directly, skipping name/email/phone entirely since the account already has them. |

**Net: everything in your spec is already built, except the confirmation-summary step and the
non-refundable notice.** Those are the one real gap — see the ticket below.

## Security review

"More secure without a complicated process" is a real tension, so worth being explicit about
where the line was drawn:

- **Already in place:** per-IP rate limiting on registration creation (20 per 10 minutes,
  `rack_attack.rb`), a separate email-bomb throttle on guest checkout, duplicate-account
  detection (an email or phone already tied to an account can't silently be reused — the visitor
  is redirected to sign in instead), and every guest account still gets a real (if unusable)
  password-protected row rather than a throwaway session.
- **Deliberately not proposed:** OTP/email verification before a registration counts. That's the
  standard way to make "who typed this contact info" actually provable, but it's exactly the kind
  of extra step your brief asks to avoid, and this app doesn't have SMS delivery wired to a real
  provider yet (see `registration-engagement-tickets.md`'s Ticket 1 — still "scaffolded, no live
  provider"). If fraud/no-show rates on guest registrations turn out to be a real problem later,
  that's the lever to pull — flagging it here so it's a conscious trade-off, not an oversight.
- **What the confirmation step below actually buys you, security-wise:** it's not
  authentication, but it does close the most common real-world failure mode — a mistyped email
  or phone number meaning the participant never receives their ticket/QR and the organizer has no
  way to reach them. Catching that before the charge happens (rather than after, via a support
  request) is the practical "more secure" win available without adding friction like OTP.

---

## Ticket — Add a pre-payment confirmation step

**Status:** Done (2026-08-24). Shows for both guest and signed-in registrations on paid events
(the open question below was resolved as "both").

**Priority:** Medium — not a bug, but the one concrete gap between the current flow and what you
described.

**Scope**
- New step in `events.$eventId.tsx`'s registration flow (`RegStep` currently: `idle → guest →
  types → survey`), inserted right before the final `register.mutate()` call, **shown only when
  the event isn't free** (flat `price_cents`, or the selected type's `effective_price_cents`,
  whichever applies) — a free registration completes immediately today and this keeps it that
  way, matching "should show the summary before proceeding to the payment page if the event is
  not free" exactly.
- Summary content: name + email/phone (from the guest form, or the signed-in account's profile —
  shown either way, since a signed-in user can still have a stale/wrong email on file), selected
  event type(s) and their price, survey answers if any, and the total amount due.
- A clear, plain-language notice near the confirm button: registrations can't be refunded for
  information entered incorrectly (wrong email, wrong phone, wrong event type) — asks the
  participant to check before continuing rather than after paying.
- Two actions: **Back** (returns to the last step actually filled in — survey, or types, or the
  guest form) and **Confirm & continue**, which is what actually calls `register.mutate()` today.
- No backend changes needed — this is purely a frontend review gate in front of the existing
  `POST /registrations` call; the API contract doesn't change.

**Open question**
- Should this summary also show for a **signed-in** user on a paid event, or only for the
  guest-checkout path? Your spec describes it under "new user," but the underlying reason (catch
  mistakes before charging) applies just as much to a signed-in user who picked the wrong event
  type. Recommend showing it in both cases — it's one extra confirm tap, not a form to refill —
  but flagging since your spec technically only describes the new-user branch.
  **Resolved:** both.

**Implementation notes (2026-08-24)**
- `events.$eventId.tsx`: new `"confirm"` step in the `RegStep` union, inserted after
  guest/types/survey (whichever apply) and before the actual `register.mutate()` call — only
  when `totalDueCents > 0` (flat event price, or the sum of selected types' own prices). A free
  registration still completes immediately with no extra step, exactly as before.
  `proceedPastLastStep()` is the new common tail every path (guest-only, +types, +survey) now
  funnels through, replacing what used to be three separate direct `register.mutate()` calls.
- Confirm screen shows name + contact (from the guest form, or the signed-in account's
  `display_name`/`phone`/`email` — skipping `email` when it's the auto-generated placeholder for
  a phone-only account), selected event type(s), the total due, and the non-refundable notice,
  with Back (returns to whichever step was actually last shown) and "Confirm & register" actions.
- `EventTypeSelector`'s `nextLabel` and `SurveyForm`'s new `submitLabel` prop both switch to
  "Review & confirm" instead of "Register"/"Complete registration" when a confirm step follows,
  so the button text doesn't imply the charge happens immediately.
- No backend changes — purely a frontend gate in front of the existing `POST /registrations`
  call, as scoped.
- All touched `.tsx` files pass an esbuild syntax/JSX check; both locale files are valid JSON.
  No frontend test runner exists in this repo (see `CLAUDE.md`) — worth a manual click-through
  (guest + signed-in, free + paid, with/without types, with/without survey) before merging.
