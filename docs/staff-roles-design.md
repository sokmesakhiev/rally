# Rally staff roles — design

**Status:** accepted · **Date:** 2026-09-27 · **Scope:** v1
**Phases 0–3a and Phase 4's backend are built.** Outstanding: the
approval UI, and Phase 3b (`remove_column :users, :admin`, its own deploy).

Rally has exactly one staff flag: `users.admin`, a boolean. Setting it so
somebody can answer support chat also grants them the ability to suspend any
account, delete any event, verify any organization, refund any payment, and
publish any event for free.

That was the right size while staff meant "the founder". It stops being the
right size the first time someone is hired to do one job.

This document proposes three staff roles with a capability matrix, in the same
shape as the one `EventAuthorization` already uses for events.

---

## 1. What exists today

`require_admin!` gates the whole `/api/v1/admin` namespace uniformly, and two
money paths sit outside it. The complete set of places that key on
`users.admin`:

**Actor checks — may this person do X?**

| Site | Today |
|---|---|
| `ApplicationController#require_admin!` | gate for the entire admin namespace |
| `ApplicationController#adoptable?` | impersonation actor must still be staff |
| `EventPlanPaymentsController#create` | `waived = current_user.admin?` — publish any event free |
| `RefundsController#create` / `#find_authorized_payment` | refund any payment on the platform |
| `SupportInboxChannel#subscribed` + `#still_staff?` | live inbox stream |
| `PingChannel.enabled_for?` | the Ticket 0 diagnostic |

**Target checks — may this person be acted upon?** These matter as much as the
actor checks and are easy to miss:

| Site | Today |
|---|---|
| `Admin::UsersController#suspend` | "Admin accounts cannot be suspended" |
| `Admin::ImpersonationsController#refusal_for` | "Admin accounts can't be impersonated" |

**Fan-out, serialization, scope**

| Site | Today |
|---|---|
| `Notifications::ModerationNotifier#admins` | `User.where(admin: true, …)` — who gets report notifications |
| `concerns/user_payload.rb` | `admin: user.admin?` — drives the frontend nav |
| `Admin::UsersController` user row | `admin: user.admin?` |
| `User.admins` scope | — |
| `site-header.tsx`, `admin.tsx` (×2), `admin-support.tsx` | client-side gates |

Thirteen sites. None of them is hard; the risk is missing one.

---

## 2. Decisions

### D1 — An enum column plus a frozen capability hash, not a permissions system

`users.staff_role`: `nil` (not staff), `"support"`, `"moderator"`, `"admin"`.
Capabilities live in a frozen hash keyed by role, exactly like
`EventAuthorization::CAPABILITIES`.

Rally will have a handful of staff, not three hundred. A `Role`/`Permission`
join-table system is the correct answer at a scale this product is nowhere
near, and the wrong answer now: it moves the authorization rules out of the
codebase and into data nobody reviews, so "who can delete an event" stops
being answerable by reading a file.

The matrix-as-data pattern is already proven here twice — the event capability
matrix and the organization owner/admin/member ladder — and a third instance
of a familiar shape is cheaper to hold in your head than a new mechanism.

*Rejected:* separate booleans (`support?`, `moderator?`). Four booleans encode
sixteen states, fourteen of which are nonsense, and there is no ordering, so
"at least a moderator" becomes an `||` chain that drifts.

### D2 — Keep `users.admin` working throughout, and cut over in two deploys

The migration adds `staff_role` and backfills `admin: true → "admin"`. It does
**not** drop `admin` in the same change.

This is the one decision where the failure mode is catastrophic rather than
annoying: get it wrong in a single deploy and nobody can administer the
platform, including the person who would fix it. Two deploys means the
rollback target is always a working console.

`User#admin?` survives as a delegation (`staff_role == "admin"`) so the
thirteen sites can move one at a time rather than in one commit.

Two columns meaning the same thing can disagree, so two things hold them
together. `User#reconcile_staff_role_and_admin_flag` syncs them in both
directions on save — the `admin = true` → role direction matters most,
because that is the console command by which admin is actually granted. And
because that callback is a `before_save` and therefore invisible to
`update_column`, `update_all`, `upsert_all` and raw SQL, a NULL-safe CHECK
constraint (`users_admin_matches_staff_role`) makes a desync impossible at the
only layer that sees every writer. Both disappear in Phase 3 with the boolean.

**Pre-check before Phase 1:** `#admin?` now reads an attribute rather than the
boolean column, so any `User.select(...)` that omits `staff_role` would raise
`ActiveModel::MissingAttributeError` where it previously returned a value.
There are no partial selects on `users` in `app/` or `lib/` today — grep again
before Phase 1 rather than assuming that held.

### D3 — `require_admin!` becomes `require_staff!(capability)`, default-deny

Same 404-not-403 philosophy: a non-staff caller gets exactly what they get
today, and the console still doesn't advertise itself.

Each admin controller declares an `ACTION_CAPABILITIES` map and looks the
capability up with `fetch`, so an action added without a declared capability
**raises** rather than silently inheriting someone else's permission. That is
not a new idea — `EventsController#authorize_creator!` already does exactly
this, and it is the best authorization idea in the codebase precisely because
the failure mode is loud.

### D4 — Three roles

`○` marks a capability that additionally needs a second person — see D9.

| Capability | support | moderator | admin |
|---|:--:|:--:|:--:|
| Read and reply to support chat | ● | ● | ● |
| Assign / resolve conversations | ● | ● | ● |
| Read the event report queue | | ● | ● |
| Resolve reports (`actioned` / `dismissed`) | | ● | ● |
| Read users and events (context for a ticket) | ● | ● | ● |
| Suspend / unsuspend an event | | ● | ● |
| Unpublish an event | | | ● |
| **Delete an event** | | | ○ |
| Suspend / unsuspend a user | | ● | ● |
| Verify a user or organization | | ● | ● |
| **Suspend an organization** | | | ○ |
| Issue a refund below `FOUR_EYES_REFUND_CENTS` | | | ● |
| **Issue a refund at or above it** | | | ○ |
| Waive a plan payment | | | ● |
| Read the analytics dashboard | | ● | ● |
| Read the audit log | | | ● |
| Impersonate | ● | ● | ● |

Verification sits with moderator because it is queue work in practice — a
backlog somebody works through — even though it is what unlocks charging
money. The compensating control is that it is reversible (`unverify`) and
audited, unlike the three `○` rows.

The split between "suspend an event" (moderator) and "delete an event"
(admin) follows the existing reasoning in `EventAuthorization`: suspension is
reversible and is the intended moderation outcome; deletion destroys an
organizer's work and the registrations attached to it.

### D5 — Money stays admin-only

Refunds and plan waivers are the two paths where value leaves the business,
they are the two that sit *outside* the admin namespace, and they are
therefore the two most likely to be missed by a future refactor. They get the
narrowest grant and a comment saying why.

A support agent who needs a refund escalates.

**`issue_capped_refund` is specified here and deliberately not built.** If
escalation turns out to bottleneck day-to-day support, the fix is a capability
that lets support refund up to a fixed ceiling — not widening `issue_refund`,
and not handing support the admin role. Writing the escape hatch down now
means that when the pressure arrives, the cheap wrong answer ("just make them
an admin") has a documented cheap right answer sitting next to it.

### D6 — Support keeps impersonation

This is the decision most likely to be overridden, so here is the whole
argument rather than the conclusion.

Impersonation is the single most useful support tool: most tickets are "I
can't see my registration", and the alternative to looking is a guessing game
conducted over chat. It is also, despite how it sounds, the **best-controlled
power on the list** — read-only enforced on the HTTP verb rather than an
endpoint allowlist, a 30-minute token, one live session per staff member, the
user notified at session start in the same transaction that opens it, and an
audit row either way.

Taking it away from support makes the role not worth creating: either every
lookup is escalated to a moderator, or moderators rubber-stamp requests
without context, which is worse than support having the power directly.

If the instinct is still to withhold it, the cheaper mitigation is tightening
`ImpersonationSession::REASON_MIN` and reviewing reasons, rather than removing
the capability — the reason field already exists and is already required.

### D7 — The protected class is "any staff", not "any admin"

`Admin::UsersController#suspend` and `Admin::ImpersonationsController` both
currently refuse when the *target* is an admin. Those checks must become "is
the target staff at all", or a support agent could suspend or impersonate a
moderator — a privilege escalation introduced by the very change meant to
reduce privilege.

### D8 — The audit log records the role, snapshotted

`AdminAction` records the actor's role at the time of the action, never
recomputed. It already carries a `metadata` jsonb column, so this needs no
migration — `metadata["actor_role"]`, written by `AdminAction.log!`.

Same reasoning as `Message#sender_role`, which is derived from position in the
thread rather than from `users.admin` precisely so that changing someone's
status doesn't retroactively relabel months of their history. An audit trail
that reads differently after a promotion is not an audit trail.

### D9 — Two people for destruction and large refunds, and nothing else

A `StaffApproval` row stands between the request and the act: one staff member
requests, a *different* one who also holds the capability approves, and only
then does it execute.

**Three actions, chosen on one principle: irreversible, or money leaving.**

| Action | Why |
|---|---|
| Delete an event | Destroys an organizer's work and the registrations attached to it. Note it already carries a `confirm=true` gate and refuses outright when any registration is paid — D9 adds a second *person*, not a second click |
| Suspend an organization | Takes down every event it presents at once. **Unsuspending is not gated** — it has its own `unsuspend_organization` capability for that reason |
| Refund ≥ `FOUR_EYES_REFUND_CENTS` | Money out, no recall |

**Reversals are never gated**, and this cost a round of red tests to learn:
`unsuspend` originally shared the `suspend_organization` capability, so
restoring a wrongly-suspended organization inherited the second-signature
requirement and every event it presents stayed down until a colleague was
free. It has its own capability now — same audience, no signature. Any future
capability covering both a destructive action and its undo needs splitting
the same way.

**Suspending an *event* is deliberately excluded**, and this is the part worth
disagreeing with me about if you're going to. Suspension is the protective
action — it is how something harmful comes down — and it is reversible.
Putting a second signature in front of it means harmful content stays up until
a second person is awake. Four-eyes belongs on destruction and money, never on
the brake pedal.

Six properties, each of which is a way this goes wrong if skipped:

- **The approver must be a different person and hold the capability
  themselves.** Otherwise it is a formality: support "approving" an admin's
  event deletion is one person with extra steps.
- **The payload is pinned.** An approval authorises *this refund of $240 on
  this payment*, not "a refund". The request's parameters are hashed into the
  approval and re-checked at execution, so an approved request can't be edited
  into a different one.
- **Single use.** Consumed on execution, so it can't be replayed.
- **Short expiry — 24 hours.** A pending "delete this event" sitting in a
  queue for a fortnight is a landmine somebody eventually steps on.
- **The executed action still writes its own `AdminAction`**, referencing the
  approval. The approval records intent; the audit row records what happened.
  Conflating them loses the difference between "asked" and "did".
- **Nothing bypasses it silently.** The capability check and the approval
  check are the same lookup, so an action declared four-eyes cannot be
  performed by a route that forgot to ask.

**The one-staff-member problem, stated plainly.** If only one person holds a
capability, nothing requiring two signatures can ever execute — including, on
a bad day, an urgent refund. The answer is to refuse, with an error that says
exactly why rather than a generic 403, and to treat the Rails console as the
break-glass. That is consistent rather than a cop-out: `admin` is already
granted only from the console today, so the console is already the root of
trust. A self-approval flag "for emergencies" would be used routinely within a
month and would quietly turn the whole mechanism into paperwork.

*Rejected:* a threshold-free rule requiring two people for everything staff
do. It reads as more secure and is less so — every control that makes routine
work painful gets routed around, usually by giving everybody the top role,
which is the exact failure this document exists to prevent.

### D10 — Granting staff access: an endpoint for the lower two roles, console for admin

Today the entire flow is one line in a production console:

```
aws ecs execute-command … --command "bin/rails console"
User.find_by(email: "…").update!(staff_role: "moderator")
```

No endpoint, no UI, no rake task, no tooling. That was a reasonable shape for
a single `admin` boolean granted twice a year. With three roles it has four
problems, and the first two are the ones that matter:

- **Role changes are the only staff action with no audit trail.** D8 stamps
  `actor_role` onto every `AdminAction`, but the act of *changing* someone's
  role writes nothing. The log can say a moderator suspended an event; it
  cannot say who made them a moderator, when, or why. Granting privilege is
  more security-relevant than exercising it, and it is the one thing not
  recorded.
- **Nobody can see who holds what.** `Admin::UsersController` serializes
  `admin:` and not `staff_role`, so the console's user list badges admins and
  shows nothing for support or moderator. An access review — "who is staff?"
  — is impossible from inside the product.
- Nobody is told they were granted or revoked, unlike impersonation.
- Nothing stops self-promotion, or demoting the last admin and locking the
  platform out in one command.

**The decision: a `manage_staff_roles` capability that grants and revokes
`support` and `moderator`, and cannot touch `admin`.**

Admin stays console-only. The original reasoning — *no endpoint for promoting
a user, so a compromised admin session can't mint more admins* — is still
exactly right for `admin`, and it is the property worth protecting above all
others: stealing one admin session must not yield unbounded, self-sustaining
access. It does not follow for the lower two roles, which are granted often,
carry less, and are currently invisible *because* of that rule. The blast
radius of a stolen admin session becomes "can create moderators" — bounded,
reversible, audited, and notified — rather than "can create admins".

Six properties:

- **`manage_staff_roles: %i[admin]`.** Only admins grant staff access.
- **Four-eyes on granting, never on revoking.** Handing someone the console
  deserves a second opinion. Taking it away must not wait for one — if an
  account is compromised at 2am you strip it immediately. This is the same
  rule that `unsuspend_organization` exists for, and it cost a round of red
  tests to learn once already: the control belongs on the direction that adds
  power, never on the recovery.
- **Audited both ways**, as `grant_staff_role` / `revoke_staff_role`, with
  the from-and-to roles in metadata. The gap this decision opens with is the
  one it must close first.
- **The person is told**, on grant and on revoke. Same reasoning as
  `ImpersonationNotifier`: a change to what someone can do, that they were
  never informed of, should not be a state the database can hold. Worth
  naming the counter-argument — revocation notifies a malicious insider that
  they have been spotted — but they discover it the moment the console 404s,
  so the notification costs nothing and the silence would only mislead the
  honest case.
- **No self-service.** You cannot change your own role in either direction,
  through the endpoint or otherwise.
- **The last admin cannot be demoted.** As a *model* validation, not a
  controller check, so the console is covered too — that path is precisely
  where the mistake would be made. `update_column` remains the deliberate
  override for a genuine recovery.

Plus the cheap fix that stands on its own regardless of the rest: put
`staff_role` in the admin user-list payload and badge it, so the question
"who is staff?" has an answer in the product.

*Rejected:* an endpoint that can grant `admin` too, four-eyes-gated. It reads
as consistent and it isn't — four-eyes protects against one person acting
alone, not against one *session* being stolen, and a stolen admin session
plus a second stolen session is a scenario that ends with the attacker
holding permanent access and the legitimate staff locked out. Console access
needs separate credentials (IAM), leaves a separate trail (CloudTrail), and
is the right second factor for the role that can do everything.

*Rejected:* leaving all three console-only and simply adding the audit and
the badge. Cheaper, and it would fix the two findings that matter. It also
means every support hire needs someone with production IAM and an ECS exec
session, which is a strange amount of privilege to need in order to give
somebody the *least* privileged role in the system.

---

## 3. Rollout

| Phase | Ships | Behaviour change |
|---|---|---|
| **0** ✅ | `staff_role` column, backfill, `User#admin?` delegating to it | none |
| **1** ✅ | `require_staff!` + capability matrix, `admin` role only | none — every existing admin keeps every power |
| **2** ✅ | `support` and `moderator` roles, frontend tab gating | new roles become usable |
| **3a** ✅ | D7 protected class, D8 audit role, code stops touching `users.admin`, CHECK constraint dropped | staff become unsuspendable and unimpersonatable; audit rows gain `actor_role` |
| **3b** | `remove_column :users, :admin` — **its own deploy** | — |
| **4** 🔶 | D9 four-eyes: `StaffApproval`, the four gated actions. **Backend only — the request/approve UI is outstanding** | destruction, plan waivers and refunds ≥ $100 need a second signature |
| **5** 🔶 | D10: grant/revoke support and moderator, audited and notified; `staff_role` visible in the user list. **Backend + badge only — the grant/revoke UI controls are outstanding** | staff membership becomes reviewable in-product |

### Phase 3b: why the column drop is its own deploy

**Do not commit the drop-column migration alongside Phase 3a.** `db:prepare`
runs every pending migration in one go on container boot, so committing both
collapses them into a single deploy and reintroduces exactly the failure this
split avoids.

A deploy rolls tasks: old code keeps serving for a minute or two after the
migration lands. Until Phase 3a is *deployed*, old code still runs the
reconcile callback, which assigns `self[:admin]`. Drop the column in the same
deploy and every user save on a not-yet-replaced task raises `UndefinedColumn`
— sign-ups and sign-ins included.

The order is therefore: **deploy 3a → confirm it is serving → commit and
deploy 3b**.

Generate it with `bin/rails generate migration` rather than hand-dating the
file — Rails 8.1 refuses a future timestamp, and this repository has been
bitten by that before.

```ruby
class RemoveAdminFromUsers < ActiveRecord::Migration[8.1]
  # Not `change`. The inverse of this needs a backfill, and a backfill isn't
  # expressible in a reversible block — see #down.
  def up
    remove_column :users, :admin
  end

  # **A rollback has to restore the data, not just the column.**
  #
  # `add_column ... default: false` brings back a column in which *every
  # admin reads as false*. That is inert while 3a's code is running, since
  # nothing reads the boolean — but the reason to keep a rollback path at all
  # is to survive a bad deploy, and a rollback far enough to redeploy
  # pre-3a code would leave that code asking `User.where(admin: true)` and
  # finding nobody. Zero admins on the platform, no console access to fix it,
  # and a rollback that reported success. That is the lock-out D2 exists to
  # prevent, reappearing at the far end of the sequence.
  #
  # The index goes with it for the same reason: Postgres drops an index with
  # its column, and `add_column` does not bring one back.
  def down
    add_column :users, :admin, :boolean, default: false, null: false
    add_index :users, :admin, where: "admin = true", name: "index_users_on_admin"
    execute("UPDATE users SET admin = true WHERE staff_role = 'admin'")
  end
end
```

Nothing reads or writes the column after 3a, so between the two deploys it is
inert — stale `false` values on new staff rows that no code consults. The one
observable effect during 3a's own rollout is that a staff member created in
that window is invisible to an old task's `User.where(admin: true)`, which
affects the moderation notifier's recipient list for a couple of minutes.

### 3b pre-flight

Checked 2026-09-28, against the code as it stands after Phase 4:

- **No reader or writer of the column remains** anywhere in `backend/app`,
  `lib`, `db`, `spec`, `e2e` or `frontend`. The surviving mentions are
  `#admin?` (which reads `staff_role`), the `admin:` key in the JSON payload
  (unaffected), and comments.
- **No other database object depends on it** except
  `index_users_on_admin`, handled in `#down` above. The CHECK constraint was
  already dropped by `20260926020000`.
- **`require_admin!` keeps working** post-drop — it calls `#admin?`, not the
  column. It is dead code either way and can be deleted whenever.

The only remaining gate is not something the codebase can answer: **3a has to
be deployed and serving.** Locally-migrated is not the same thing. If old
tasks are still running the reconcile callback when the column disappears,
every user save on them raises `UndefinedColumn` — sign-ups and sign-ins
included.

### Phase 3b: why the column drop is its own deploy

**Do not commit the drop-column migration alongside Phase 3a.** `db:prepare`
runs every pending migration in one go on container boot, so committing both
collapses them into a single deploy and reintroduces exactly the failure this
split avoids.

A deploy rolls tasks: old code keeps serving for a minute or two after the
migration lands. Until Phase 3a is *deployed*, old code still runs the
reconcile callback, which assigns `self[:admin]`. Drop the column in the same
deploy and every user save on a not-yet-replaced task raises `UndefinedColumn`
— sign-ups and sign-ins included.

The order is therefore: **deploy 3a → confirm it is serving → commit and
deploy 3b**.

Generate it with `bin/rails generate migration` rather than hand-dating the
file — Rails 8.1 refuses a future timestamp, and this repository has been
bitten by that before.

```ruby
class RemoveAdminFromUsers < ActiveRecord::Migration[8.1]
  # Not `change`. The inverse of this needs a backfill, and a backfill isn't
  # expressible in a reversible block — see #down.
  def up
    remove_column :users, :admin
  end

  # **A rollback has to restore the data, not just the column.**
  #
  # `add_column ... default: false` brings back a column in which *every
  # admin reads as false*. That is inert while 3a's code is running, since
  # nothing reads the boolean — but the reason to keep a rollback path at all
  # is to survive a bad deploy, and a rollback far enough to redeploy
  # pre-3a code would leave that code asking `User.where(admin: true)` and
  # finding nobody. Zero admins on the platform, no console access to fix it,
  # and a rollback that reported success. That is the lock-out D2 exists to
  # prevent, reappearing at the far end of the sequence.
  #
  # The index goes with it for the same reason: Postgres drops an index with
  # its column, and `add_column` does not bring one back.
  def down
    add_column :users, :admin, :boolean, default: false, null: false
    add_index :users, :admin, where: "admin = true", name: "index_users_on_admin"
    execute("UPDATE users SET admin = true WHERE staff_role = 'admin'")
  end
end
```

Nothing reads or writes the column after 3a, so between the two deploys it is
inert — stale `false` values on new staff rows that no code consults. The one
observable effect during 3a's own rollout is that a staff member created in
that window is invisible to an old task's `User.where(admin: true)`, which
affects the moderation notifier's recipient list for a couple of minutes.

### 3b pre-flight

Checked 2026-09-28, against the code as it stands after Phase 4:

- **No reader or writer of the column remains** anywhere in `backend/app`,
  `lib`, `db`, `spec`, `e2e` or `frontend`. The surviving mentions are
  `#admin?` (which reads `staff_role`), the `admin:` key in the JSON payload
  (unaffected), and comments.
- **No other database object depends on it** except
  `index_users_on_admin`, handled in `#down` above. The CHECK constraint was
  already dropped by `20260926020000`.
- **`require_admin!` keeps working** post-drop — it calls `#admin?`, not the
  column. It is dead code either way and can be deleted whenever.

The only remaining gate is not something the codebase can answer: **3a has to
be deployed and serving.** Locally-migrated is not the same thing. If old
tasks are still running the reconcile callback when the column disappears,
every user save on them raises `UndefinedColumn` — sign-ups and sign-ins
included.

Phase 4 is last and separate on purpose. It is the only phase that adds a
model, a queue and a second UI surface, and folding it into the role split
would make Phase 1's "no behaviour change" claim false — which is the property
that makes the rest of this safe to verify.

Phase 1 changing **no** behaviour is the point of the ordering: it is the
phase that proves the new mechanism grants exactly what the old one did,
against the existing request specs, before anybody's access is narrowed.

---

## 4. What will make this go wrong

- **Missing one of the thirteen sites.** The mitigation is a spec that walks
  every route under `/admin` and asserts each resolves to a declared
  capability — the same executable-guard pattern as the PayWay serializer
  spec and the e2e reset-route spec. A prose checklist will not survive the
  next feature.
- **Locking everyone out.** Addressed by D2's two-deploy cutover.
- **The frontend believing it is the gate.** `admin.tsx` already carries a
  comment saying the server is authoritative and the client check only decides
  whether to render. That must stay true for five tabs with three different
  audiences.
- **Role sprawl.** Three roles is a guess. If a fourth is proposed within a
  quarter, the matrix was wrong rather than incomplete, and it is worth
  re-reading §2 before adding a row.

---

## 5. Decisions taken (2026-09-27)

The four questions this document opened with have been answered:

1. **Support gets impersonation.** D6 stands as written.
2. **Refunds stay admin-only**, with `issue_capped_refund` specified but not
   built — see D5. Revisit the moment escalation becomes a daily tax rather
   than an occasional one.
3. **Moderators verify** users and organizations. Moved in D4.
4. **Two people for destruction and large refunds.** D9, shipping as Phase 4.

### Known inconsistency, not introduced here

`SurveysController#authorize_owner!` is `survey.creator_id == current_user.id`
— strictly the one person — while `EventAuthorization` grants **organization
admins owner-level access to the events they present**. So a club's second
admin can edit an event and cannot read its survey.

This predates the staff-role work (`#update` and `#destroy` were already
creator-only; `#show` merely joined them when the IDOR was closed) and it is
invisible today, because `surveysApi.get` / `update` / `delete` have no call
sites at all — surveys are built inline during event creation. It is recorded
here because the fix belongs with whichever phase teaches surveys about
organizations, and because "no caller hits this" is a reason to defer, not a
reason to forget.

### Still to settle

- **Do small plan waivers need a signature?** Every waiver is gated today.
  A Free or Small tier waiver going through the same ceremony as a $2,000
  Extra Large may be friction with no payoff; `FOUR_EYES_WAIVER_CENTS` was
  the alternative and remains unbuilt.
- **Who staffs the second signature out of hours?** A control that can't be
  satisfied at 2am on a Sunday is a control that gets bypassed. This is an
  operational answer, not a code one, and it should exist before Phase 4
  ships rather than after the first urgent refund.
