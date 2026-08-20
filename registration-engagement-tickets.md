# Registration engagement — follow-up tickets

Written up 2026-08-19 after a review of the current event registration flow (see
`app/services/registrations/guest_checkout.rb`, `Api::V1::RegistrationsController#create`,
`RegistrationMailer`, `Waitlists::PromoteNext`). Each ticket is scoped independently — pick
any subset to implement first.

---

## Ticket 1 — SMS/phone confirmation for phone-only guests

**Status: Scaffolded, no live provider (2026-08-19)** — the send path is now fully wired
into the registration flow, but goes through a stub (`Sms::Adapters::NullAdapter`) that
logs the message instead of delivering it. Nothing is actually sent to a real phone yet.

What's in place:
- `Sms::Client` (`backend/app/services/sms/client.rb`) — dispatches to an adapter picked by
  `SMS_PROVIDER` (defaults to `"null"`). Adding a real provider later is a one-file change:
  a new `Sms::Adapters::<Provider>` implementing `#deliver(to:, body:)`, registered in
  `Sms::Client::ADAPTERS`.
- `Sms::Adapters::NullAdapter` — logs `[sms:null] would send to ...` and reports success.
- `Registrations::SendPhoneConfirmation` — builds the message (event title, date, ticket
  link) for a phone-only guest, mirroring `RegistrationMailer#confirmation`.
- `SendPhoneConfirmationJob` — background wrapper, enqueued from
  `RegistrationsController#create` in place of the mailer branch when
  `registrant.email_auto_generated?` is true (previously that branch did nothing at all).
- Specs: `spec/services/sms/client_spec.rb`, `spec/services/registrations/send_phone_confirmation_spec.rb`,
  `spec/jobs/send_phone_confirmation_job_spec.rb`, plus two new request specs in
  `registrations_spec.rb` asserting the job is enqueued and `Sms::Client.deliver` is called
  with the right phone number and message.

**Priority:** High — this is the primary registrant path the guest-checkout feature was
built for, and it currently produces zero real confirmation (the stub only logs).

**Why it matters**
Phone is Cambodia's primary contact channel — it's the reason phone-only checkout exists.
A registrant with no durable record of their registration (no email receipt, nothing sent
to their phone) has no way to confirm what they signed up for after they close the tab.

**Remaining work — needs a provider decision before it can go live**
- Pick an SMS/messaging provider reachable in Cambodia. Global aggregators (Twilio, Plivo,
  Vonage, Infobip) all technically route to Cambodia; SEA-focused specialists (MoceanAPI,
  EasySendSMS, BudgetSMS) may offer better on-net rates/deliverability for local carriers.
  Needs a decision + an account before any adapter beyond the null stub can be written.
- Once a provider's picked: add `Sms::Adapters::<Provider>` implementing
  `#deliver(to:, body:)`, register it in `Sms::Client::ADAPTERS`, set `SMS_PROVIDER` in the
  environment. No changes needed to `Registrations::SendPhoneConfirmation`,
  `SendPhoneConfirmationJob`, or the controller — they already call through `Sms::Client`.
- Add credentials to `.env.example` / `infrastructure/secrets.tf` following the existing
  `ABA_PAYWAY_*` pattern.
- Rate-limit the send path — no `guest_registrations/*`-style throttle currently exists in
  `config/initializers/rack_attack.rb` for the registration-creation endpoint at all (only
  the blanket `registrations/ip` 20/10min limit). Worth adding a per-phone throttle
  alongside a real provider, so the endpoint can't be used to spam a specific number with
  billable messages.

**Open questions**
- Which SMS provider/gateway — needs a decision before a real adapter can be built.
- Budget/cost per message, since this is a per-registration send.

---

## Ticket 2 — Ticket recovery for phone-only guests

**Priority:** High — directly follows from Ticket 1; without a delivery channel this has
no way to reach the guest at all.

**Problem**
A phone-only guest's ticket QR only exists in their current browser session (the
guest-checkout JWT is stored in `localStorage`, see `api-client.ts`). If they close the tab,
clear storage, or switch devices, there's no way back in — no email link to click, and no
password they could use to sign in (guest accounts get a `SecureRandom.hex(32)` password
they never see).

**Why it matters**
Losing the ticket means losing check-in access at the event with no self-service recovery
path — this becomes a support/at-the-door problem for organizers.

**Proposed scope**
- Depends on Ticket 1: the SMS/message send should include either the ticket link directly
  or enough for the guest to get back to it.
- A fallback "find my ticket" page: enter the phone number used at registration, receive a
  one-time code via the same channel as Ticket 1, then view the ticket QR without needing
  the original password-less account's real credentials.

**Open questions**
- Whether the one-time-code lookup should also double as a lightweight way to finally set a
  real password (tying into the existing "add a real email" nudge).

---

## Ticket 3 — Auto-release abandoned unpaid registrations

**Priority:** Medium-high — a real capacity-integrity bug on paid, capacity-limited events,
even though it's not user-facing until an event actually fills up.

**Problem**
For a paid event, `RegistrationsController#create` creates the `Registration` row (status
`confirmed`, `payment_status: "unpaid"`) as soon as the guest/type/survey steps are done —
before any ABA KHQR payment succeeds. `Registration.active` (used by `Event#full?` and the
capacity validation) only excludes `status: "cancelled"`, not unpaid ones — so an unpaid
registration holds a real capacity slot. `Payment#expired?` exists and
`PaymentsController#refresh_if_stale!` will mark a stale `Payment` row `"expired"`, but
nothing ever touches the `Registration` itself: if the participant abandons the KHQR screen
(closes the tab, the code times out), the registration stays `unpaid` and the slot stays
claimed indefinitely.

**Why it matters**
On a capacity-limited paid event, this lets abandoned checkout attempts silently consume the
whole event, blocking people who would actually pay, with no automatic recovery — someone
has to notice and manually clean it up.

**Proposed scope**
- A recurring background job (Solid Queue is already running in-process via
  `SOLID_QUEUE_IN_PUMA` — see `config/recurring.yml` for the existing pattern) that finds
  registrations that are `unpaid` with no `approved` payment and whose most recent payment
  attempt (or the registration itself, if no payment was ever started) is past a grace
  window.
- Cancel those registrations via the existing `Registration#discard!`/cancel path, then call
  `Waitlists::PromoteNext` the same way `RegistrationsController#destroy` already does, so
  the freed slot goes to whoever's next in line.
- Decide the grace window (e.g. KHQR expiry + N minutes) and whether to notify the
  abandoning participant at all (probably not, since they walked away).

**Open questions**
- Grace period length.
- Whether a registration with no payment attempt at all yet (submitted, KHQR never even
  requested) should be swept too, and after how long.

---

## Ticket 4 — Push notifications for signed-in participants

**Priority:** Medium — largest infrastructure lift of the five; best scoped after 1–3 land.

**Problem**
No push notification infrastructure exists anywhere in the codebase today — no service
worker, no push subscription storage, no web push sending. Dashboard visibility itself
already works (a signed-in or auto-signed-in guest sees their registrations via
`GET /api/v1/registrations` on `/dashboard`), but there's no proactive notification on top
of it.

**Why it matters**
Relying solely on email (and, once Ticket 1 lands, SMS) means every notification is a
one-way send with no in-app equivalent for people who do have accounts and keep the app
open/installed.

**Proposed scope**
- Web push (VAPID keys) is the natural fit given the frontend is a static SPA (see
  "Frontend: TanStack Start file-based routing" — no SSR, so this is client + backend only,
  no server-rendered push triggers needed).
- New `PushSubscription` model (user_id, endpoint, keys) + a JS service worker registration
  in the frontend, gated behind a permission prompt (don't request on page load — tie it to
  an explicit user action, e.g. right after a successful registration).
- Fire pushes from the same trigger points the existing mailers already use:
  `RegistrationMailer#confirmation`, `#promoted_from_waitlist`, `#payment_received` — reuse
  the existing `Registration#wants_notification?` opt-out plumbing rather than building a
  parallel preferences system.

**Open questions**
- Whether this needs a native app eventually or stays web-push-only for now.
- Additional `notify_*` preference columns, or reuse the existing ones per notification type.

---

## Closed — Event QR deep-link (not needed)

Originally proposed making the event QR jump straight into the register form instead of
landing on the event detail page. Reviewed and dropped: showing event details (price, date,
capacity) before asking someone to commit is the right default, especially for paid or
capacity-limited events — most scanners want to see what they're registering for first. No
change needed here.
