# Event membership — tickets

Scoped 2026-08-26 after auditing the request against the current codebase.

**The ask:** running a gathering takes more than one person. An event owner should be able to
invite people to help run their event.

**Confirmed gap:** there is no concept of an event team today. Every organizer-only endpoint
resolves to exactly one person — the row's `creator_id` — across 20 endpoints in 8
controllers. There is no membership table, no invitation flow, and no shared authorization
helper to hang one off.

**Decisions taken up front** (agreed before scoping, so the tickets below assume them):

1. **A fixed set of roles**, not per-permission checkboxes and not a single all-powerful
   co-organizer. Three roles — Manager, Check-in staff, Viewer — plus the existing owner.
   Rationale: a race-day check-in volunteer should not be able to issue refunds or change
   pricing, but building a full permission matrix is disproportionate to the number of jobs
   that actually exist at a gathering.
2. **Email invitations with a tokenized accept link.** The owner types any email address; the
   recipient signs up or signs in, then joins. Most volunteers won't have a Rally account yet,
   so "existing accounts only" would push the owner into chasing people out of band. Mirrors
   the token pattern already used by password resets and email verification.

---

## Current authorization surface

Two hand-rolled idioms, no Pundit/CanCanCan, no shared concern:

- **404-style** — `current_user.events.find(...)`, rescued into `404 "Event not found"`. Used
  by `events#activity`, `registrations#event_registrations`, `registrations#export`,
  `event_plan_payments#create`/`#show`, `survey_responses#index`, `results#import`.
- **403-style** — `unless event.creator_id == current_user.id` → `403 "Forbidden"`. Used by
  `events#update`/`#destroy`/`#unpublish` (via `authorize_creator!`),
  `registrations#update`/`#destroy`/`#check_in`/`#undo_check_in`, `results#update`,
  `waitlist_entries#event_waitlist`, `refunds#index`/`#create` (via `find_authorized_payment`,
  which also allows platform admins).

The split is not principled — it's just how each controller was written. Ticket B unifies it
before any role logic is layered on, because adding a second dimension (role) to two divergent
idioms across 8 files is how inconsistent gaps get introduced.

`Api::V1::BaseController` is currently 3 lines (`include ValidateParams`) and every controller
in the table inherits from it — the natural home for a new `EventAuthorization` concern.

---

## Proposed permission matrix

| Capability (endpoint) | Owner | Manager | Check-in | Viewer |
|---|:--:|:--:|:--:|:--:|
| View event dashboard (`events#show` organizer view) | ✅ | ✅ | ✅ | ✅ |
| View participant list (`registrations#event_registrations`) | ✅ | ✅ | ✅ | ✅ |
| Check in / undo check-in (`registrations#check_in`, `#undo_check_in`) | ✅ | ✅ | ✅ | ❌ |
| Edit event details (`events#update`) | ✅ | ✅ | ❌ | ❌ |
| Remove participant (`registrations#destroy`) | ✅ | ✅ | ❌ | ❌ |
| Update payment status (`registrations#update`) | ✅ | ✅ | ❌ | ❌ |
| Issue refunds (`refunds#create`, `#index`) | ✅ | ✅ | ❌ | ❌ |
| Manage waitlist (`waitlist_entries#event_waitlist`) | ✅ | ✅ | ❌ | ✅ (read) |
| Set results (`results#update`, `#import`) | ✅ | ✅ | ❌ | ❌ |
| View survey responses (`survey_responses#index`) | ✅ | ✅ | ❌ | ✅ |
| View activity log (`events#activity`) | ✅ | ✅ | ❌ | ✅ |
| CSV export (`registrations#export`) | ✅ | ✅ | ❌ | ❌ |
| Publish / change plan (`event_plan_payments#create`) | ✅ | ❌ | ❌ | ❌ |
| Unpublish (`events#unpublish`) | ✅ | ❌ | ❌ | ❌ |
| Delete event (`events#destroy`) | ✅ | ❌ | ❌ | ❌ |
| Invite / remove / re-role members | ✅ | ❌ | ❌ | ❌ |

Three deliberate exclusions from Manager, all with the same reasoning — they either spend the
owner's money or change who controls the event:

- **Plan payments** charge the owner's card, and `Event::PLANS` tiers are the owner's
  commercial decision.
- **Delete / unpublish** destroy or hide work that isn't theirs; `Admin::EventsController` and
  the owner both retain these.
- **Member management** — letting a Manager add Managers means the owner can be diluted out of
  their own event with no audit trail they'd notice.

**CSV export is Manager-only, not Viewer**, even though Viewer can already page through the
same participants in the UI. Bulk export is a different risk (one click, whole attendee list,
off-platform) and Viewer is the role you'd hand to a sponsor or a board member.

---

## Proposed schema

```ruby
# event_memberships — an accepted, active team member
create_table :event_memberships, id: :uuid do |t|
  t.references :event, type: :uuid, null: false, foreign_key: true
  t.references :user,  type: :uuid, null: false, foreign_key: true
  t.string     :role,  null: false            # manager | check_in | viewer
  t.references :invited_by, type: :uuid, foreign_key: { to_table: :users }
  t.datetime   :accepted_at, null: false
  t.timestamps
  t.index [ :event_id, :user_id ], unique: true
end

# event_invitations — a pending invite, before the recipient has an account/accepted
create_table :event_invitations, id: :uuid do |t|
  t.references :event, type: :uuid, null: false, foreign_key: true
  t.string     :email, null: false
  t.string     :role,  null: false
  t.references :invited_by, type: :uuid, null: false, foreign_key: { to_table: :users }
  t.string     :token, null: false
  t.datetime   :expires_at, null: false
  t.datetime   :accepted_at
  t.datetime   :revoked_at
  t.timestamps
  t.index :token, unique: true
  t.index [ :event_id, :email ], unique: true, where: "(accepted_at IS NULL AND revoked_at IS NULL)"
end
```

Two tables rather than one nullable-user row: an invitation is a message with a lifecycle
(sent, expired, revoked, accepted) addressed to an email that may never become a user, whereas
a membership is a live grant tied to a real account. Collapsing them means every authorization
query has to filter out non-accepted rows forever, and the unique index that should protect
"one membership per person per event" can't be a plain two-column unique.

`ROLES = %w[manager check_in viewer].freeze` on `EventMembership`, inclusion-validated, mirroring
`EventActivity::ACTIONS` and `Event::PLANS`.

---

## Ticket A — Membership + invitation schema and models

**Priority:** High — everything else depends on it.

**Scope**

- Both migrations above, plus `db/schema.rb`.
- `EventMembership` model: `belongs_to :event`, `belongs_to :user`, `belongs_to :invited_by`
  (optional), `ROLES` constant + inclusion validation, uniqueness validation on
  `[event_id, user_id]` to match the index.
- `EventInvitation` model: token generation (`SecureRandom.urlsafe_base64(32)`, matching
  `User#generate_email_verification_token!`), `EXPIRY = 14.days`, `pending?`/`expired?`/
  `accepted?`/`revoked?` predicates, and a `.find_by_valid_token` class method following
  `User.find_by_valid_email_verification_token`'s shape.
- `Event` associations: `has_many :event_memberships, dependent: :destroy`,
  `has_many :members, through: :event_memberships, source: :user`,
  `has_many :event_invitations, dependent: :destroy`.
- `User`: `has_many :event_memberships, dependent: :destroy`,
  `has_many :member_events, through: :event_memberships, source: :event`.
- Factories + model specs.

**Decision needed inside this ticket:** `Event#discard!` currently cascades only to
registrations and waitlist entries. Memberships should almost certainly be left alone (the
event is soft-deleted, not gone; undeleting it shouldn't lose the team) — but this must be
stated explicitly rather than left to `dependent: :destroy` semantics on a soft delete.

**Acceptance criteria**

- Migrations run clean; a user cannot hold two memberships on one event.
- An invitation's token is unique, expires after 14 days, and `.find_by_valid_token` returns
  nil for expired, revoked, and already-accepted invitations.

---

## Ticket B — Centralize organizer authorization (no behaviour change)

**Priority:** High — must land before Ticket C, and is valuable on its own.

**Problem**

The same authorization decision is expressed 20 times, two different ways, with two different
failure modes (404 vs 403). Layering roles onto that as-is means 20 independent chances to get
a role check subtly wrong, and no single place to read off "who can do what."

**Scope**

- New `app/controllers/concerns/event_authorization.rb`, included in
  `Api::V1::BaseController`. Public surface:
  - `authorize_event!(event, :capability)` — raises/renders on failure.
  - `event_role_for(event)` — returns `:owner`, `:manager`, `:check_in`, `:viewer`, or `nil`.
  - A `CAPABILITIES` constant: the permission matrix above, as data, in one place.
- Refactor all 20 endpoints to call it. **This ticket changes no behaviour** — with no
  memberships in the database, `event_role_for` returns `:owner` or `nil` and every endpoint
  responds exactly as it does today.
- Settle the 404-vs-403 split as part of this: recommend **404 for "you have no relationship
  with this event at all"** (don't confirm the event exists to a stranger, matching
  `require_admin!`'s existing philosophy) and **403 for "you're on the team but this role can't
  do this"** (they already know the event exists; a 404 would just be confusing). Existing
  specs asserting the current codes will need updating where the two disagree.

**Acceptance criteria**

- Full suite green with no membership rows present.
- Every organizer-gated endpoint routes through the concern — a grep for `creator_id ==` and
  `current_user.events.find` in `app/controllers/api/v1/` (excluding `admin/`) returns nothing.

---

## Ticket C — Apply role gating

**Priority:** High. **Depends on:** A, B.

**Scope**

- Fill in `CAPABILITIES` per the matrix and have `event_role_for` consult
  `EventMembership` when the user isn't the creator.
- `events#my_events` currently lists `current_user.events` (events you created). Extend it to
  include events you're a member of, tagging each with the caller's role so the dashboard can
  render "Owner"/"Manager" and hide actions the role lacks. **This is the change most likely to
  be forgotten** — without it an invited member has no way to reach the event at all.
- Refunds: `find_authorized_payment` currently allows `organizer? || current_user.admin?`.
  Extend the organizer arm to Manager, leave the admin arm untouched.

**Acceptance criteria**

- Request specs per role × per capability, asserting both allow and deny.
- A Check-in member can check someone in but gets 403 on `events#update`, `refunds#create`,
  and `registrations#export`.
- A member of any role sees the event in `GET /api/v1/events/my`, with their role in the payload.
- Revoking a membership immediately revokes access (no token/session caching).

---

## Ticket D — Invite a member

**Priority:** High. **Depends on:** A, B.

**Scope**

- `POST /api/v1/events/:event_id/invitations` — owner-only. Params: `email`, `role`.
  Request schema following `ApplicationRequestSchema`, with `role` inclusion-validated.
- Guard rails, each with a machine-readable `code:` per house convention: inviting the owner
  themselves (`code: "self_invite"`), inviting someone already a member
  (`code: "already_member"`), a duplicate pending invite (`code: "invite_pending"`).
- New `EventInvitationMailer#invite` (html + text), following `EventMailer`'s shape and using
  `ApplicationMailer#frontend_url` to build the accept link
  (`/events/:event_id/invitations/:token`). Sent with `deliver_later`.
- `GET /api/v1/events/:event_id/invitations` — owner-only, lists pending invites.
- `DELETE /api/v1/events/:event_id/invitations/:id` — owner-only, sets `revoked_at`.
- Log `invite_member` / `revoke_invitation` to `EventActivity` (see Ticket H).

**Acceptance criteria**

- Inviting a brand-new email sends one email containing a working tokenized link.
- Inviting an existing member returns 422 with `code: "already_member"` and sends nothing.
- A revoked invitation's token no longer resolves.
- Non-owners (including Managers) get 403.

---

## Ticket E — Accept an invitation

**Priority:** High. **Depends on:** D.

**Scope**

- `GET /api/v1/invitations/:token` — public, unauthenticated. Returns just enough to render
  the landing page (event title, inviter's display name, role, whether it's still valid).
  Deliberately minimal: this endpoint is reachable by anyone holding the link.
- `POST /api/v1/invitations/:token/accept` — authenticated. Creates the `EventMembership`,
  stamps `accepted_at`, logs `member_joined`.
- **Email-match policy — needs a decision.** Simplest and safest is to require the signed-in
  user's email to match the invitation's (`code: "invitation_email_mismatch"` otherwise). The
  looser alternative (any signed-in user holding the token may accept) makes forwarded invites
  work, which organizers may well want, but turns the link into a bearer credential — the exact
  property we rejected shareable join links for. Recommend strict matching, with the mismatch
  error naming the invited address so the user knows which account to use.
- Frontend route `/events/$eventId/invitations/$token`: renders the invite, sends an
  unauthenticated visitor through signup/signin and back (the existing `_authenticated` layout
  redirect pattern), then calls accept.

**Acceptance criteria**

- A user with no Rally account can follow the link, sign up, and land on the event as a member.
- An expired or revoked token renders a clear "this invitation is no longer valid" state, not
  a generic error.
- Accepting twice is idempotent — no duplicate membership, no 500 from the unique index.

---

## Ticket F — Manage existing members

**Priority:** Medium. **Depends on:** A, B, C.

**Scope**

- `GET /api/v1/events/:event_id/members` — visible to any member (you should be able to see
  who else is on the team); returns display name, avatar, role, joined-at.
- `PATCH /api/v1/events/:event_id/members/:id` — owner-only, changes role.
- `DELETE /api/v1/events/:event_id/members/:id` — owner-only, removes. Also allow a member to
  remove *themselves* (leave the event) — otherwise the only exit is asking the owner.
- The owner is not an `EventMembership` row; `#index` should synthesize them into the list as
  `role: "owner"` so the UI doesn't have to special-case an absent first entry.

**Acceptance criteria**

- Owner can promote a Viewer to Manager and demote back.
- A removed member immediately loses access to every gated endpoint.
- A Manager attempting any of the write actions gets 403.

---

## Ticket G — Frontend: Members tab and role-aware UI

**Priority:** Medium. **Depends on:** C, D, F.

**Scope**

- New **Members** tab on the manage-event page. Note `TabsList`'s grid columns are currently
  `grid-cols-7`/`grid-cols-6` behind a `ev?.survey_id` ternary
  (`dashboard_.events.$eventId.tsx`) — adding a tab makes it 8/7 and both `max-w-*` values need
  widening.
- Invite form (email + role select), pending-invitations list with revoke, member list with
  role change and remove. Owner-only; other roles see a read-only roster.
- **Role-aware chrome throughout the page** — a Check-in member shouldn't see a Branding tab
  and a disabled Delete button, they should see the tabs their role can use. Drive this off the
  role returned by `events#my_events`/`events#show`. As with `PaidEventGate`, this is an
  affordance, not a security boundary; the server re-checks everything.
- i18n keys in **both** `en.json` and `km.json`, in lockstep.

**Acceptance criteria**

- Owner can complete the whole loop — invite, see pending, revoke, change role, remove — without
  leaving the tab.
- Signing in as a Check-in member shows the Check-in and Participants tabs and nothing else.

---

## Ticket H — Activity logging for membership changes

**Priority:** Low, but cheap — do it alongside D–F rather than after.

**Scope**

- Add to `EventActivity::ACTIONS` (currently `%w[remove_participant update_event_details]`,
  inclusion-validated — `log!` raises on anything else): `invite_member`, `revoke_invitation`,
  `member_joined`, `remove_member`, `change_member_role`.
- Log from the relevant actions with metadata (`email`, `role`, `from`/`to` for role changes).
- Extend the Activity Logs tab's renderer to describe the new action types.

`EventActivity` already has `belongs_to :actor, class_name: "User"` and resolves `actor_name`
from profile-or-email, so member-authored entries render correctly with no change — this is
what makes the log actually useful once more than one person can act on an event.

---

## Issues found while scoping

Not part of this feature, but surfaced by the audit and worth tracking:

1. **`UploadsController` has no ownership check at all.** `POST /api/v1/uploads` is gated only
   by `authenticate_user!` — any signed-in user can upload a banner/logo/certificate template
   and receive a blob URL. Attaching it to an event *is* creator-gated (via `events#update`),
   so this isn't currently an event-takeover path, but it is an unauthenticated-storage-cost
   and content-hosting vector. Worth its own ticket regardless of membership.

2. **Surveys are user-scoped, not event-scoped.** `Survey belongs_to :creator` and `Event
   belongs_to :survey` — a survey is a reusable library object owned by a user, attachable to
   any of their events. So `surveys#update`/`#destroy` can't be role-gated by event membership
   without a decision: leave surveys owner-only (recommended — a Manager editing a survey would
   silently change every *other* event it's attached to), or scope edit rights to surveys
   attached to an event you manage. The matrix above assumes the former; `survey_responses#index`
   (the answers for one event) is event-scoped and is included.

3. **`AuthController#delete_account` blocks deletion when you organize events with paid
   registrations**, querying `Event.where(creator_id: current_user.id)`. Membership doesn't
   change that query's correctness (it's about the owner's money), but once "organizer" can
   mean more than the creator, this is a spot where the two meanings diverge — worth a comment
   so the next reader doesn't "fix" it.

4. **`results#index` is public** (`except: [ :index ]`) — correctly so, since finish times are
   published. Flagging only so it isn't swept into the role matrix by mistake.

---

## Open questions

1. **Can a Manager invite Check-in staff?** The matrix says no — all member management is
   owner-only. For a large event the owner may not want to be the bottleneck for adding
   volunteers on race morning. A narrower alternative: Managers may invite Check-in and Viewer,
   but not Managers. Worth deciding before Ticket D.
2. **Ownership transfer.** Out of scope here, but membership makes it newly plausible ("promote
   a Manager to owner"). If it's wanted, it should be its own ticket — it moves billing and the
   `delete_account` guard along with it.
3. **Do members count against anything?** `Event::PLANS` caps *registrations*, not staff. Assuming
   team size is unlimited and free; if members should be capped by tier, that changes Ticket F.
4. **Notifications.** Should a member be emailed when they're removed or re-roled? The existing
   `Profile#notify_*` opt-out pattern would extend naturally, but nothing here assumes it.
