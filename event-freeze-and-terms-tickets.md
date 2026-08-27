# Event freeze & Terms of Service — tickets

Scoped 2026-08-27 after auditing the request against the current codebase.

**The ask, in two parts:**

1. Today, `Admin::EventsController#unpublish` is the only moderation lever stronger than
   deleting an event outright — and it's trivially reversible by the event owner (they just
   re-publish through `EventPlanPaymentsController#create`, free of charge under the same plan).
   For an event that's actively being used to scam people or is otherwise harmful, the platform
   needs a lever the *owner cannot undo* — a **freeze**, admin-only to lift, with the owner
   notified by email why it happened.
2. New accounts should have to accept Terms of Service before the platform will create them.

**Decisions taken up front** (answered before scoping, so the tickets below assume them):

1. **Freeze blast radius:** same as today's unpublish (drops off public listings, `is_published`
   forced `false`) plus the owner-can't-undo part. Registrations/payments are left untouched —
   refunding attendees stays a separate, manual admin decision, same philosophy
   `Event#destroy`/`Admin::EventsController#destroy` already uses (refuses to hard-delete a paid
   event; a freeze doesn't touch payments either).
2. **A required reason**, shown to the owner in the notification email — mirrors
   `User#suspend!(reason:)` exactly, and gives the owner something concrete if they want to
   dispute it.
3. **Terms of Service copy is a placeholder**, not real legal text — engineering builds the
   mechanism (versioned acceptance, blocks signup until accepted) with clearly-marked draft copy;
   legal review of the actual wording happens before launch, separately.

---

## Current state

**Unpublish today (`Admin::EventsController#unpublish`):** sets `is_published: false`, logs an
`AdminAction`, nothing else. The owner can undo it themselves at any time — `is_published` isn't
settable via `events#update` (see `EventUpdateRequestSchema`'s exclusion comment), but
`EventPlanPaymentsController#create` republishes for free when `event.plan == plan` (the
existing plan), no charge, no admin involvement. That's the exact gap: "unpublish" is a
suggestion the owner can quietly reverse.

**The `User#suspend!`/`#unsuspend!` precedent** (`suspended_at`/`suspension_reason` columns,
checked per-request in `authenticate_user!`, not just at sign-in) is the shape to mirror for
`Event`. One thing that pattern does *not* do, which this ticket set adds: it never emails the
suspended user. There is no existing precedent anywhere in the app for "email someone about an
admin moderation action taken against them" — `EventMailer`/`RegistrationMailer`/`UserMailer` are
all self-service or organizer-initiated. This is genuinely new.

**Authorization chokepoint:** every organizer-gated endpoint already routes through
`EventAuthorization#event_permits?` (see `event-membership-tickets.md`'s Ticket B/C — this
concern now covers all 16 capabilities in `CAPABILITIES`). Freezing needs to deny every
*mutating* capability regardless of role, while still allowing the owner to *view* the event
(so they can see why it's frozen) — one guard in `event_permits?`, not 16 call-site changes.

**Signup today (`AuthController#signup`):** no terms/agreement concept anywhere in `User`,
`AuthSignupRequestSchema`, or the signup form (`routes/auth.tsx`). Google sign-in
(`AuthController#google` → `User.find_or_create_from_google!`) is a second account-creation path
with no form step at all — a naive "add a checkbox to the signup form" fix silently misses it.

---

## Proposed schema

```ruby
# Event: two new columns, same shape as users.suspended_at/suspension_reason
add_column :events, :frozen_at, :datetime
add_column :events, :freeze_reason, :string
add_index  :events, :frozen_at

# Users: acceptance is versioned, not a boolean — so a future ToS update can require
# re-acceptance without conflating "never agreed" with "agreed to an old version"
add_column :users, :terms_accepted_at, :datetime
add_column :users, :terms_version, :string
```

`Event::FROZEN_ALLOWED_CAPABILITIES` (or equivalent) — the `view_*` capabilities that stay
readable while frozen: `view_event`, `view_participants`, `view_waitlist`,
`view_survey_responses`, `view_activity`. Everything else (`update_event`, `manage_plan`,
`unpublish_event`, `delete_event`, `manage_members`, `export_participants`, `check_in`,
`update_registration`, `remove_participant`, `issue_refund`, `manage_results`) is denied
outright when `event.frozen?`, independent of role — including the owner's own `unpublish`/
`delete`, so a frozen event's evidence trail can't be tidied away mid-investigation.

`TermsOfService::CURRENT_VERSION` (a small module/constant, e.g. `"2026-08-27"`) — one place the
signup flow and any future "please re-accept" gate both read from.

---

## Ticket A — Event freeze: schema, model, authorization lockdown

**Priority:** High — everything else depends on it.

**Scope**

- Migration above, plus `db/schema.rb`.
- `Event#frozen?`, `Event#freeze!(reason:)` (sets `frozen_at`/`freeze_reason`, forces
  `is_published: false` in the same transaction — mirrors `User#suspend!`), `Event#unfreeze!`
  (clears both columns; does **not** re-publish, same "that's the owner's decision" reasoning
  `User#unsuspend!` already uses for events).
- `EventAuthorization#event_permits?`: short-circuit to `false` when `event.frozen?` and the
  capability isn't in the read-only allowlist above — before the existing role check runs, so
  it applies to every role including owner.
- `EventPlanPaymentsController#create` (the actual republish path) needs no code change if the
  above lands first — `find_authorized_event!(..., :manage_plan, ...)` already raises
  `RecordNotFound` (404) once `manage_plan` is denied. Confirm this in the ticket's specs rather
  than assuming it.
- Expose `frozen`/`freeze_reason`/`frozen_at` in `event_json` wherever `EventsController#show`,
  `#my_events`, and `Admin::EventsController#event_json` already build their payloads.

**Acceptance criteria**

- A frozen event's owner is denied `update`/`unpublish`/`destroy`/`manage_plan`/
  `manage_members`, and every other role gets the same. The status code matches
  whichever of the two existing entry points the endpoint already used before this
  ticket (`authorize_event!` → 403, e.g. `EventsController#update`/`#destroy`/`#unpublish`;
  `find_authorized_event!` → 404, e.g. `EventPlanPaymentsController#create`) — freezing
  doesn't change that per-endpoint choice, only whether the underlying check passes.
- The owner (and any team member) can still `GET` the event, participants, waitlist, survey
  responses, and activity log while frozen.
- Freezing an already-unpublished event still works (freeze and publish state are independent
  axes — an event can be a frozen draft).
- `Event#unfreeze!` never flips `is_published` back to `true`.

---

## Ticket B — Admin freeze/unfreeze endpoints

**Priority:** High. **Depends on:** A.

**Scope**

- `POST /api/v1/admin/events/:id/freeze` — body: `{ reason: }`, required (`AdminFreezeEventRequestSchema`,
  following `AdminSuspendUserRequestSchema`'s shape). Calls `event.freeze!(reason:)`,
  `log_admin_action("freeze_event", event)`.
- `POST /api/v1/admin/events/:id/unfreeze` — no body. `event.unfreeze!`,
  `log_admin_action("unfreeze_event", event)`.
- Both added to `Admin::EventsController` alongside the existing `unpublish`/`destroy`, same
  `Event.find` + `rescue ActiveRecord::RecordNotFound` pattern.
- Routes under the existing `namespace :admin` block in `config/routes.rb`.
- Decide (open question below): does freezing an already-frozen event update the reason, or
  reject as a no-op? Recommend: allow — an admin refining the reason shouldn't have to unfreeze
  first.

**Acceptance criteria**

- Freezing renders the event with `frozen: true`, `freeze_reason` set.
- A blank/missing `reason` is rejected with 422 before anything is persisted.
- Unfreezing an event that was never frozen is a harmless no-op, not an error.
- Both actions produce a queryable `AdminAction` row (`GET /api/v1/admin/admin_actions`).

---

## Ticket C — Freeze notification email

**Priority:** High. **Depends on:** A, B.

**Scope**

- `EventMailer#frozen(event)` — new method, same shape as `#created`. Recipient: `event.creator`.
  Subject along the lines of `"Your event \"#{event.title}\" has been frozen"`. Body includes
  `event.freeze_reason` (per the up-front decision — reason is shared with the owner) and a
  plain-language explanation that this is a platform decision requiring admin action to reverse,
  not something they can undo themselves.
- Wire `EventMailer.frozen(event).deliver_later` into `Admin::EventsController#freeze`, right
  after `event.freeze!(reason:)` succeeds.
- **Deliberately no `#unfrozen` counterpart in this ticket** — unfreezing is comparatively
  low-stakes (an admin correcting course), and the up-front scoping decision kept participant-
  and secondary-notification behavior minimal this round. Flagged as an open question below in
  case that's wrong.
- Not gated by any `Profile#notify_*` toggle — same reasoning as `EventMailer#created`: this is
  the platform informing the owner of a decision about their own event, not an opt-outable
  secondary notice.

**Acceptance criteria**

- Freezing an event enqueues exactly one email, to the creator, containing the reason text
  verbatim.
- Unfreezing sends nothing (until/unless the open question above is resolved otherwise).
- Freezing an event whose owner has no profile (edge case, mirrors other mailers) still sends —
  the template doesn't depend on `Profile` data.

---

## Ticket D — Frontend: admin console freeze/unfreeze UI

**Priority:** Medium. **Depends on:** B.

**Scope**

- `adminApi.freezeEvent(id, reason)` / `adminApi.unfreezeEvent(id)` in `api-client.ts`, alongside
  the existing `suspendUser`/`unsuspendUser`.
- In `routes/_authenticated/admin.tsx`'s events tab: a `FreezeEventDialog` component mirroring
  the existing `SuspendUserDialog` almost exactly (`AlertDialog` + required reason `Textarea`,
  not optional — the backend rejects a blank one) next to the existing unpublish/delete actions,
  plus an "Unfreeze" button shown only when `ev.frozen`.
- A "Frozen" badge on the admin event row/list, same visual slot as the existing "Suspended"
  badge pattern (`ev.creator.suspended` → badge).
- i18n keys in both `en.json`/`km.json`.

**Acceptance criteria**

- An admin can freeze an event with a reason and see the "Frozen" badge appear without a page
  reload (query invalidation, same pattern as `SuspendUserDialog`'s `onDone`).
- The reason field can't be submitted empty (client-side guard mirroring the backend's).
- Unfreeze is a single click, no confirmation dialog needed (matches `unsuspend`'s existing
  lack of one) — reversing course should be low-friction; freezing should not be.

---

## Ticket E — Frontend: manage-event page reflects a frozen event

**Priority:** Medium. **Depends on:** A (frozen/freeze_reason exposed via `events#show`).

**Scope**

- `dashboard_.events.$eventId.tsx`: when `ev.frozen`, render a persistent banner (reason
  included) above the tabs, and disable/hide every mutating control the same way the existing
  `can` object already gates by role (Branding tab, Certificate tab, Delete/Unpublish buttons,
  Publish/Change-plan sections, Members tab's manage controls, participant remove/mark-paid) —
  reusing that object rather than adding a parallel `frozen` check at each call site. Read-only
  tabs (Participants, Activity, Members roster) stay visible per Ticket A's allowlist.
- Public event detail page (`routes/events.$eventId.tsx`): a frozen event is already excluded
  from `events#index`'s published/upcoming scope, so it simply won't appear in listings — but
  direct-link access via `events#show` still 200s (per Ticket A's read-allowlist). Decide
  whether the public page should show a "this event is no longer available" state instead of
  the normal detail page when `role` is absent/stranger and `frozen` is true (recommended, since
  a stranger following an old link to a frozen scam event seeing full details defeats the
  point) — flagged as an open question below since it wasn't part of the original ask.

**Acceptance criteria**

- The owner sees the freeze reason and cannot reach any disabled control via direct
  interaction (not just hidden — the underlying mutation would 404 anyway per Ticket A, but the
  UI shouldn't invite the attempt).
- A Manager/Viewer/Check-in team member on a frozen event sees the same read-only restriction,
  not just the owner.

---

## Ticket F — Terms of Service: schema + signup enforcement

**Priority:** High — everything else in the ToS half depends on it.

**Scope**

- Migration above (`terms_accepted_at`, `terms_version` on `users`), plus `db/schema.rb`.
- `TermsOfService` module/constant: `CURRENT_VERSION`. One place, so a future re-acceptance flow
  reads the same value the signup path stamps.
- `AuthSignupRequestSchema`: add `required(:terms_accepted).filled(:bool)` (or equivalent),
  rejecting `false`/missing with a clear `code: "terms_not_accepted"` — deliberately a schema-
  level rejection (422 before any DB write), not a silent default.
- `AuthController#signup`: on success, stamp `terms_accepted_at: Time.current,
  terms_version: TermsOfService::CURRENT_VERSION` on the new user in the same transaction as
  `user.save!`.
- **Explicitly out of scope for this ticket:** retroactively enforcing acceptance for existing
  accounts. The ask was scoped to signup; existing users are not gated on this. Flagged as an
  open question below in case that's wrong.

**Acceptance criteria**

- Signup without `terms_accepted: true` returns 422 with `code: "terms_not_accepted"` and
  creates no user row.
- A successful signup stamps both `terms_accepted_at` and `terms_version` correctly.
- Existing users (created before this ships) are entirely unaffected — no forced re-accept, no
  behavior change to their sign-in.

---

## Ticket G — Frontend: signup checkbox + placeholder ToS/Privacy content

**Priority:** High. **Depends on:** F.

**Scope**

- `routes/auth.tsx`'s sign-up form: a required checkbox ("I agree to the Terms of Service and
  Privacy Policy", with the two terms linked) before the submit button becomes enabled — mirrors
  the existing client-side `validateSignUp` pattern (block submission, translated error, no
  server round-trip for the obvious case).
- `authApi.signup(...)` gains a `termsAccepted: boolean` param, sent as `terms_accepted`.
- Two new static content routes/pages, **clearly marked as placeholder/draft** in an HTML
  comment and in a visible "Draft — pending legal review" banner: `/terms` and `/privacy`. Content
  is boilerplate SaaS ToS/Privacy language, not reviewed legal text — this ticket's job is
  unblocking the mechanism, not producing binding copy.
- i18n keys in both `en.json`/`km.json` for the checkbox label, links, and validation error.

**Acceptance criteria**

- The sign-up button is disabled (or submission is blocked with an inline error) until the
  checkbox is checked.
- `/terms` and `/privacy` render and are linked from the checkbox label.
- Submitting signup sends `terms_accepted: true`; unchecking-then-resubmitting cannot bypass the
  client check by editing hidden state (server-side rejection from Ticket F is the real
  backstop regardless).

---

## Ticket H — Terms of Service gap: Google sign-in

**Priority:** Medium. **Depends on:** F.

**Problem**

`AuthController#google` creates brand-new accounts via `User.find_or_create_from_google!` with
no form step at all — Ticket G's checkbox never runs for this path. Shipping F+G alone would
mean email/password signups accept terms and Google signups silently don't.

**Scope**

- `User.find_or_create_from_google!`: **only on the newly-created-account branch** (not the
  existing-account sign-in branches), leave `terms_accepted_at`/`terms_version` nil rather than
  auto-stamping — auto-accepting terms on someone's behalf without them seeing anything is worse
  than the current gap.
- New endpoint, `POST /api/v1/auth/accept_terms` — authenticated, stamps
  `terms_accepted_at`/`terms_version` on `current_user`. Idempotent (already-accepted is a
  no-op, not an error).
- Frontend: after a Google sign-in response where `user.terms_accepted_at` is null, show a
  one-time, dismissable-only-by-accepting interstitial (same checkbox/links as Ticket G) before
  proceeding into the dashboard, then call `accept_terms`.

**Acceptance criteria**

- A brand-new Google sign-in is asked to accept terms before reaching the dashboard.
- An existing Google-authenticated user (already has an account, whether or not they'd accepted
  under an older flow) is never interrupted by this on subsequent sign-ins once they've accepted
  once.
- Declining/closing the interstitial leaves the account created but `terms_accepted_at` nil —
  decide (open question below) whether that should block continued use, block nothing, or
  something in between.

---

## Issues found while scoping

Not part of this feature, but surfaced by the audit and worth tracking:

1. **`is_published` really has three independent-ish axes now** (published/unpublished,
   suspended-account cascade, and after this ships, frozen) with three different owners of the
   "can this flip back to true" question (organizer, organizer via unsuspend, admin-only via
   unfreeze). Worth a follow-up doc comment on `Event#is_published` itself once this lands, so
   the next reader isn't left reconstructing which axis blocked republishing from three separate
   files.
2. **`User#suspend!` still sends no email either.** This ticket set only adds a notification for
   event freezes, per the ask — but the same "admin took an action, nobody was told" gap exists
   for account suspension. Worth its own ticket if the business wants parity.

---

## Open questions

1. **Should unfreezing notify the owner too?** Scoped out of Ticket C above (freeze-only) to
   match the original ask precisely — but an owner who never finds out their event is usable
   again seems like an easy miss. Cheap to add if wanted.
2. **Should a frozen event's public page (for a stranger following an old link) show a distinct
   "no longer available" state**, rather than just falling out of search/browse listings while
   still rendering normally for anyone with the direct URL? Flagged in Ticket E.
3. **Freezing an already-frozen event** — Ticket B recommends allowing it (updates the reason).
   Confirm that's actually wanted vs. rejecting with "already frozen."
4. **What happens to a Google sign-in who never accepts terms** (Ticket H)? Options: block all
   further API access until accepted (harshest), block nothing (defeats the point), or allow
   read-only/browsing but block registering/creating events until accepted (middle ground,
   mirrors how `User#suspended?` already blocks selectively rather than universally).
5. **Retroactive enforcement for existing accounts** (flagged in Ticket F) — out of scope today,
   but if the business wants every existing user to accept on next sign-in, that's a new ticket
   (likely: a `terms_version` mismatch check in `authenticate_user!` or a post-login gate,
   analogous to the suspended/discarded checks already there).
