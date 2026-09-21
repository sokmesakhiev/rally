# Rally admin impersonation — design

**Status:** proposed · **Date:** 2026-09-18 · **Scope:** v1

A Rally staff admin opens a support ticket that says "I can't publish my
event". Today they have two ways to answer it: ask the organizer for
screenshots, or read the database. The first is slow and usually produces the
wrong screenshot; the second shows rows, not the screen the organizer is
looking at, and most "I can't" problems live in what the UI renders for that
person's role, plan and event state.

This document describes a third way: a staff admin can open the app **as** that
user, see exactly what they see, and change nothing.

The design is mostly a list of things impersonation must never be able to do.
That emphasis is deliberate. Impersonation is the single most dangerous feature
a platform can build — it is, by construction, an authentication bypass that
the company builds for itself — and on a product that holds payment
credentials and takes real money, a weak version of it is worse than not having
it. The four decisions the request settled (read-only; the user is told; money
is off limits; identity is off limits) are the ones that make it defensible,
and each is enforced structurally rather than by staff discipline.

---

## 1. Decisions

### D1 — A separate, short-lived, revocable token — never a flag on the normal JWT

Starting a session mints a **new** JWT with a different shape and a 30-minute
expiry:

```ruby
{
  user_id: <target user id>,   # unchanged key, deliberately — see below
  act:     <admin user id>,    # "actor", who is really driving
  imp:     true,
  sid:     <impersonation_sessions.id>,
  exp:     30.minutes.from_now
}
```

**`user_id` still means the target.** That single choice is what keeps this
feature small: `ApplicationController#authenticate_user!` sets `@current_user`
to the target, and every one of the ~40 existing controllers keeps working with
no changes at all. `EventsController#authorize_creator!`, `Event.publicly_visible`,
`Registration.search`, the capability checks — all of them already express
"what may this user see", and impersonation is precisely the request to answer
that question for someone else. An implementation that instead threaded an
`impersonated_user` through the app would have to touch every authorization
site, and the first one missed would be a hole.

**Not a claim on the existing token**, because Rally's JWTs live 30 days
(`JsonWebToken::EXPIRY`). A 30-day impersonation credential is not a support
tool, it is a skeleton key with a month-long life that lands in ALB access logs
and browser storage. Same reasoning that put ActionCable behind a 30-second
single-use ticket rather than the JWT (see CLAUDE.md, "Backend: ActionCable").

*Rejected:* a session cookie for the admin surface. Rally has no sessions at
all (`ActionController::API`, no Devise), and introducing one for this feature
alone means a second auth mechanism to reason about forever.

### D2 — Read-only is enforced by HTTP verb, default-deny, in one place

```ruby
# ApplicationController
before_action :refuse_writes_while_impersonating

def refuse_writes_while_impersonating
  return unless impersonating?
  return if request.get? || request.head?

  render json: {
    error: "Read-only: this is an impersonated session.",
    code: "impersonation_read_only"
  }, status: :forbidden
end
```

The check is on the **verb, not a list of endpoints**, and that is the whole
point: a controller added next year is covered on the day it's written, by
someone who has never read this document. An allowlist of safe endpoints would
have exactly the failure mode `TAB_GRID_CLASSES` had on the manage-event tab
bar — a hand-maintained list that silently stops matching reality (CLAUDE.md,
"Frontend: the manage-event tab bar").

Rally's API is honest about verbs: every mutation is POST/PATCH/PUT/DELETE and
every read is GET. Two consequences worth stating:

- `POST /api/v1/cable/ticket` is a write by this rule, so **an impersonated
  session gets no WebSocket**. That is the right outcome anyway — the socket
  exists to deliver support chat, and staff are the *other side* of that
  conversation.
- Any future "search" endpoint implemented as a POST because the query got long
  would be refused. That's a fair price for default-deny, and the fix is to
  keep reads as GETs.

### D3 — Read-only is not sufficient: some GETs are blocked too

"Read-only" protects the user's *data* from staff, not the user's *secrets*.
Two GETs leak things impersonation should never expose, so they are refused
outright rather than merely not-writable:

Both payloads that carry them — `GET /api/v1/profile` and the organization
payload — return `payway_merchant_id` and `payway_api_key_masked` as **null**
in a support session, via `ApplicationController#payway_identity_fields`.

**Nulled, not 403'd** (a change from the first draft of this document, made
while implementing it). Blanket-refusing the endpoint would have hidden
`payway_configured` along with the secret — and "is my payment setup complete"
is one of the most common things support is asked. A flag saying *whether* a
credential exists is not the credential, so the booleans stay truthful and only
the identifiers disappear. `payway_hidden: true` rides along so the UI can say
"hidden in a support session" rather than rendering the not-configured empty
state, which would tell a support admin (and anyone on the screen share) that
this organizer hasn't set up payments when they have.

Two specs guard it, because the obvious one isn't enough: a behavioural spec
deep-scans the impersonated responses for a non-null identifier, and a
source-level spec asserts that `ApplicationController` is the only file in
`app/controllers/` that serializes those keys at all. The first can only cover
endpoints someone remembered to list; the second covers the third serializer
that doesn't exist yet. Same shape as the conversation-retention spec that
reads the frontend locale files — what it prevents is a promise made to a user
(here, in the notification email) quietly becoming false.

**Account and identity are covered by D2 already** — password change, email
change, account deletion and admin promotion are all writes, so they are
refused by the verb rule with nothing extra. Recording that here because the
request named them explicitly: they are blocked, just not by a second
mechanism.

### D4 — An impersonation token can never satisfy `require_admin!`

```ruby
def require_admin!
  return head :not_found if impersonating?   # before the admin check, not after
  ...
end
```

Without this, impersonating an admin account would launder one admin's actions
through another admin's identity, and the audit trail would name the wrong
person. With it, **impersonating an admin is pointless rather than forbidden** —
the session opens, and the admin console 404s exactly as it does for anyone
else.

Starting a session against an admin account is *additionally* refused at the
endpoint, so the intent is visible in the audit log rather than inferred from
a 404. Two mechanisms here, unlike D3, because this one is the privilege
escalation: if the endpoint check is ever relaxed by someone who thinks
"admins should be able to help each other", the token check still holds.

### D5 — Revocation needs state, so there is a row

A stateless token cannot be withdrawn, and a 30-minute window is long enough to
matter when the reason for revoking is "that laptop was stolen". Every
impersonated request re-reads `impersonation_sessions` by `sid` and refuses if
the row is missing, revoked, or past `expires_at`.

That is one extra query per impersonated request and **zero** for everyone
else — the lookup happens only when `imp` is present in the payload. The same
trade the codebase already makes for `user.suspended?` on every request
(ApplicationController): a stateless token that keeps working after the fact it
depended on has changed is the bug, and a cheap indexed read is the fix.

### D5a — The actor is re-checked too, not just the session

*Added after review; the first implementation had this wrong.*

`#adoptable?` asks three questions per request, and the third was missing:
the row still permits this; the token's `user_id` and `sid` agree; and **the
actor is still staff** (`admin?`, not suspended, not discarded). A token proves
who *opened* a session. It says nothing about whether they still work here, so
without the third check, demoting or suspending an admin left their open
session working for the remainder of its 30 minutes — straight through an
offboarding, which is the exact window the whole feature most needs to be
closed in. `SupportInboxChannel`'s `ACCESS_RECHECK` learned this on the socket
side; this is the HTTP counterpart, and it's free because the request is
already loading the row.

### D5b — The optional token readers still never render

*Also added after review.*

`authenticate_user_optional!` (guest checkout) and `identify_current_user!`
(public event pages) both promise that a bad token leaves `current_user` nil
rather than producing an error — those routes were never gated on sign-in, so
a stale token must give what an anonymous visitor gets. The first version of
the impersonation guard rendered a 401 from inside them, turning a forgotten
key in localStorage into an error page on ungated routes. `adopt_impersonation!`
now takes `strict:`.

**The write refusal does not soften with it.** A dead session degrades to
anonymous; a *live* one on a non-GET is refused in both modes. Degrading there
would let an impersonated session complete a guest-checkout registration as an
anonymous guest — read-only failing open in the one place it matters most.

### D6 — Time-boxed at 30 minutes, one live session per admin

`expires_at` is set at creation and never extended; a longer look means
starting a new session, which writes a new audit row and sends the user a new
notification. An admin who leaves a tab open overnight is not still inside
someone's account.

One live session per admin, by partial unique index on `admin_id WHERE
ended_at IS NULL AND revoked_at IS NULL` — the same shape and reasoning as the
support chat's one-live-thread-per-participant index (CLAUDE.md, "Support
chat"). Two simultaneous impersonations by one person is not a workflow, it is
a mistake or an attack.

**"Ended" is evaluated, never stored as a flag.** `#live?` is
`ended_at.nil? && revoked_at.nil? && expires_at > Time.current`, so expiry
needs no cron job flipping rows across the table and there is no window where
a session has expired but the flag hasn't caught up. Same decision, and the
same reasoning, as `registration_closes_at` (CLAUDE.md, "Backend: closing
registration"). A daily tidy that stamps `ended_at` on expired rows is
cosmetic, for the admin history view, and its absence cannot make an expired
session work.

### D7 — A reason is required, and the user reads it

`POST /admin/impersonations` requires `reason` (10–500 chars). It is stored on
the session row and **quoted verbatim in the notification the user receives**.

This is the cheapest control in the document and probably the most effective
one. Writing "checking Sokmesa's publish error from ticket #412" takes four
seconds; writing it knowing Sokmesa will read it is what makes casual
curiosity feel like what it is. Free text rather than a dropdown, because a
dropdown is a list of excuses to click through.

### D8 — The user is told, in the same transaction that opens the session

An in-app `Notification` (kind `account_impersonated`) and an email, both
written inside the `create!` that opens the session. A session that exists but
was never announced is therefore not a state the database can hold.

- **Written at start, not at end.** The request asked for "after the fact",
  meaning no consent gate blocking support — not "as late as possible". Telling
  them at the start needs no sweep job to catch expired sessions and no
  ordering subtlety, and it gives the one user who genuinely didn't expect this
  a chance to say so while it's happening.
- **The in-app row is always written**, matching the house rule for every other
  notifier. There is deliberately **no `notify_*` preference column**: this one
  is not an announcement you might reasonably mute, and offering to mute it
  would be offering to make impersonation quiet.
- **The email is the durable half.** An in-app notification can be read and
  forgotten, or missed entirely by an organizer who signs in twice a year.
  Unlike the support-reply email, this one *does* carry content — the admin's
  reason and the timestamp — because the whole purpose is a record the user
  keeps outside Rally.
- The email names Rally and the reason, and **does not name the individual
  admin**. Staff identity is in `admin_actions` for internal accountability;
  putting a named employee in an email to a frustrated organizer invites the
  wrong kind of follow-up.

### D9 — Audit: two rows, plus a line per request

- `admin_actions`: `impersonate_user` at start, `end_impersonation` at stop,
  both targeting the `User`. This is the existing audit table and the admin
  history view already renders it (CLAUDE.md, "Support chat: staff endpoints").
- **Every impersonated request logs one line** — `[impersonation] actor=<id>
  subject=<id> sid=<id> GET /api/v1/events/123` — to the log aggregator, not to
  Postgres. A DB row per request would out-produce every other audit source
  combined, the same reason `read` isn't audited on the support console. The
  log line is what answers "what did they actually look at" during an
  investigation.
- Sentry gets both ids (`set_sentry_user` already exists; it gains the actor).

### D10 — The admin's own session survives, in a separate storage key

`localStorage["rally_token"]` is untouched; the impersonation token lives in
`localStorage["rally_impersonation_token"]`, and `getToken()` prefers it when
present. Ending a session is `localStorage.removeItem` of one key.

Stated because the obvious implementation — overwrite `rally_token`, restore it
after — has an obvious failure: any crash, refresh-at-the-wrong-moment or
tab-close mid-session logs the admin out of their own account, and the recovery
is a password sign-in. **You must always be able to leave**, and the way to
guarantee that is to never have left.

### D11 — Suspended, deleted and admin accounts can't be impersonated

Refused at the endpoint for all three. The first two follow from what
`authenticate_user!` already does — it refuses suspended and discarded
accounts on every request, so a session against one would mint a token that
instantly 403s and leave a misleading audit row saying staff entered an account
they couldn't enter. The third is D4.

A session already open when its target is suspended or deleted simply stops
working at the next request, via the checks already in `authenticate_user!`. No
new code, and it fails in the safe direction.

### D12 — The frontend shows a banner and does not try to disable buttons

A persistent, unmissable bar across the top: who is being impersonated,
read-only, time remaining, and **Exit**. The rest of the app renders exactly as
that user sees it, Save buttons included, and a write that reaches the server
comes back `403 impersonation_read_only`, which `api-client.ts` surfaces as one
clear toast.

Disabling every mutating control would mean maintaining a second, parallel
model of "what is a write" in the frontend — the list that goes stale, again.
Letting the refusal come from the one place that actually enforces it keeps the
client honest, and the cost is a toast an admin sees when they forget.

---

## 2. Session lifecycle

```
admin console → Users tab → "Impersonate" → reason modal
   │
   ├─ POST /api/v1/admin/impersonations { user_id, reason }
   │     ├─ refuse: self, admin, suspended, discarded, already-live session
   │     ├─ transaction:
   │     │     ImpersonationSession.create!(admin:, user:, reason:, expires_at: 30.min)
   │     │     Notifications::ImpersonationNotifier.started(session)   # in-app + email
   │     │     AdminAction.log!(action: "impersonate_user", target: user)
   │     └─ → { token:, expires_at:, user: {...} }
   │
   ├─ frontend stores it under rally_impersonation_token, banner appears
   │
   └─ ends by: Exit (DELETE /admin/impersonations/current)
              │ expiry (30 min, evaluated per request)
              │ target suspended/deleted mid-session
              └ revocation by another admin
```

---

## 3. Endpoints

| Method | Path | Notes |
|---|---|---|
| `POST` | `/api/v1/admin/impersonations` | `{ user_id, reason }` → token. Throttled `impersonations/admin`, 10/hour, in `rack_attack.rb`. |
| `DELETE` | `/api/v1/admin/impersonations/current` | Ends the caller's live session. Accepts the **admin's own** token, not the impersonation token — ending is a write, and a write can't come from an impersonated session (D2). |
| `GET` | `/api/v1/admin/impersonations` | History, for the admin console: who, whom, when, reason, how it ended. |
| `POST` | `/api/v1/admin/impersonations/:id/revoke` | Any admin can kill any live session. |
| `GET` | `/api/v1/auth/me` | Gains `impersonation: { by_admin: true, expires_at, reason }` when the token is one, so a page refresh doesn't lose the banner. |

`GET /api/v1/notifications` already carries the user's own record of it.

---

## 4. Data model

```ruby
create_table :impersonation_sessions, id: :uuid do |t|
  t.references :admin,   null: false, foreign_key: { to_table: :users }, type: :uuid
  t.references :user,    null: false, foreign_key: true, type: :uuid
  t.text     :reason,     null: false
  t.datetime :expires_at, null: false
  t.datetime :ended_at
  t.datetime :revoked_at
  t.references :revoked_by, foreign_key: { to_table: :users }, type: :uuid
  t.string   :ip
  t.string   :user_agent
  t.timestamps
end

add_index :impersonation_sessions, :admin_id,
  unique: true,
  where: "ended_at IS NULL AND revoked_at IS NULL",
  name: "index_impersonation_sessions_one_live_per_admin"
add_index :impersonation_sessions, [:user_id, :created_at]
```

Plus `account_impersonated` added to `Notification::KINDS` — noting for whoever
writes it that `KINDS` is a `%w[]` array with **no comment syntax inside it**;
commentary goes above the constant.

Retention: these rows are the audit trail, so they are kept. They hold no
message content and no personal data beyond two user ids and the staff-written
reason, so the 12-month rule that applies to support threads doesn't apply
here.

---

## 5. Frontend

- `ImpersonationBanner` — mounted in `__root.tsx` beside `SupportChat`, renders
  `null` unless impersonating. Fixed to the top, high contrast, with a live
  countdown and Exit.
- `use-auth.tsx` — `impersonation` state from `/auth/me`; `exitImpersonation()`
  clears the key and refetches.
- `api-client.ts` — `getToken()` prefers the impersonation key; a
  `impersonation_read_only` response raises a typed error the toast layer
  recognises.
- `AdminUsers` (in `admin.tsx`) — an Impersonate action per row, behind a modal
  that requires the reason.
- `SupportChat` renders `null` while impersonating, for the same reason the
  socket is refused: staff must not read or write the participant's side of a
  thread they are the other half of.
- New `impersonation.*` i18n block in `en.json` **and** `km.json`, in lockstep.
  The banner is the one piece of UI here a non-English-reading organizer might
  see over a screen share, so it is translated like everything else.

---

## 6. What this does not do

- **It is not "log in as" for fixing things.** An admin who needs to change
  something uses the admin console (which has its own audited actions) or asks
  the organizer. If a recurring support task genuinely needs a staff-side
  write, that task should get its own audited admin endpoint — which is
  reviewable in a way "an admin did it as them" never is.
- **It does not see PayWay credentials** (D3).
- **It does not reach the admin console** (D4).
- **It does not open a WebSocket** (D2).
- **It does not touch `rally_token`** (D10).

---

## 7. Rollout

**Phase 1 — backend.** Migration, `ImpersonationSession`, the token shape,
`authenticate_user!` changes, D2/D3/D4 guards, the notifier, audit, rack-attack
throttle, specs. Nothing is reachable yet: no endpoint is exposed to the UI.

The specs that matter, and that should be written first: a write is refused on
every verb; `require_admin!` 404s under an impersonation token; a PayWay-bearing
GET 403s; a revoked session stops working on the next request; an expired one
stops working with no job having run; the notification and the session row are
created or neither is.

**Phase 2 — admin console + banner.** The Users-tab action, the reason modal,
the banner, the i18n block.

**Phase 3 — visibility.** An "account access" list on the user's own profile
page showing every session against their account, and an admin history view.
Phase 3 is what turns "we told you" into "you can check", and it should not
slip indefinitely.

---

## 8. Open questions

1. **Should the organizer be able to opt out?** A toggle reading "require my
   approval before support can view my account" is defensible, and would mostly
   be turned on by the accounts most likely to complain. It also means support
   sometimes can't help. Not in v1; worth revisiting if anyone ever objects.
2. **30 minutes — right?** Long enough to reproduce a publish failure, short
   enough that nobody works a whole ticket inside someone's account. Easy to
   change, and a reason to change it is a signal worth reading.
3. **Should a session be refused while the target has a payment in flight?**
   An organizer at the KHQR screen is the exact moment when a support admin
   would most want to look, and also the exact moment when a stray click is
   most expensive. Read-only makes the click impossible, so v1 does not refuse.
4. **Do we want per-request paths in Postgres after all?** Log lines expire
   with the log retention. If an investigation ever needs "what did they look
   at" six months later, this becomes a real question.
