#!/usr/bin/env bash
#
# Creates the eight event-membership tickets from event-membership-tickets.md as
# GitHub issues on sokmesakhiev/rally, and (optionally) adds them to a project board.
#
# Written to be run by you, not by CI — it needs your own `gh` auth.
#
#   Prerequisites:  gh auth login          (one-off, if you haven't already)
#   Dry run:        ./scripts/create-event-membership-issues.sh --dry-run
#   For real:       ./scripts/create-event-membership-issues.sh
#   With a board:   ./scripts/create-event-membership-issues.sh --project 3
#
# --dry-run prints every issue it would create without touching GitHub. Run that
# first — this script creates eight issues, and un-creating them is manual.
#
# Idempotency: re-running WILL create duplicates. It checks for an existing open
# issue with the same title first and skips it, but that check is title-exact —
# if you edit a title on GitHub, the next run recreates it.

set -euo pipefail

REPO="sokmesakhiev/rally"
LABEL="event-membership"
DRY_RUN=false
PROJECT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --project) PROJECT="${2:-}"; shift 2 ;;
    --repo)    REPO="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if ! command -v gh >/dev/null 2>&1; then
  echo "gh CLI not found. Install it: https://cli.github.com" >&2
  exit 1
fi

if ! $DRY_RUN && ! gh auth status >/dev/null 2>&1; then
  echo "gh is not authenticated. Run: gh auth login" >&2
  exit 1
fi

# ── Labels ────────────────────────────────────────────────────────────────────
# Created up front so `gh issue create --label` doesn't fail on a missing label.
ensure_label() {
  local name="$1" color="$2" desc="$3"
  if $DRY_RUN; then
    echo "[dry-run] ensure label: $name"
    return
  fi
  gh label create "$name" --repo "$REPO" --color "$color" --description "$desc" 2>/dev/null \
    || true  # already exists
}

ensure_label "$LABEL"      "0E8A16" "Event membership / team roles feature"
ensure_label "backend"     "1D76DB" "Rails API"
ensure_label "frontend"    "5319E7" "TanStack Start app"
ensure_label "priority:high"   "B60205" "Blocking or foundational"
ensure_label "priority:medium" "FBCA04" "Normal"
ensure_label "priority:low"    "0E8A16" "Nice to have"
ensure_label "security"    "D93F0B" "Security-relevant"

# ── Helper ────────────────────────────────────────────────────────────────────
created_urls=()

create_issue() {
  local title="$1" labels="$2" body="$3"

  local existing
  existing=$(gh issue list --repo "$REPO" --state open --search "\"$title\" in:title" \
               --json title,url --jq ".[] | select(.title == \"$title\") | .url" 2>/dev/null || true)
  if [[ -n "$existing" ]]; then
    echo "SKIP (already open): $title"
    echo "     $existing"
    return
  fi

  if $DRY_RUN; then
    echo "────────────────────────────────────────────────────────────────────"
    echo "[dry-run] would create: $title"
    echo "[dry-run] labels: $labels"
    echo "$body"
    echo
    return
  fi

  local url
  url=$(gh issue create --repo "$REPO" --title "$title" --label "$labels" --body "$body")
  echo "CREATED: $title"
  echo "     $url"
  created_urls+=("$url")

  if [[ -n "$PROJECT" ]]; then
    gh project item-add "$PROJECT" --owner "${REPO%%/*}" --url "$url" >/dev/null \
      && echo "     added to project $PROJECT" \
      || echo "     WARNING: could not add to project $PROJECT (check the number and your scopes)" >&2
  fi
}

SPEC_NOTE=$'\n\n---\nFull scoping doc, including the permission matrix and open questions: `event-membership-tickets.md` in the repo root.'

# ── A ─────────────────────────────────────────────────────────────────────────
# bash 3.2 (macOS default) mis-parses a heredoc inside $( ), so the body is
# read into a variable at top level first rather than inline in the call.
read -r -d '' _BODY_1 <<'BODY' || true
Foundational ticket for event membership — everything else depends on it.

## Scope

Two tables. An invitation is a message with a lifecycle (sent, expired, revoked, accepted) addressed to an email that may never become a user; a membership is a live grant tied to a real account. Collapsing them means every authorization query has to filter out non-accepted rows forever, and the unique index protecting "one membership per person per event" can't be a plain two-column unique.

```ruby
create_table :event_memberships, id: :uuid do |t|
  t.references :event, type: :uuid, null: false, foreign_key: true
  t.references :user,  type: :uuid, null: false, foreign_key: true
  t.string     :role,  null: false            # manager | check_in | viewer
  t.references :invited_by, type: :uuid, foreign_key: { to_table: :users }
  t.datetime   :accepted_at, null: false
  t.timestamps
  t.index [ :event_id, :user_id ], unique: true
end

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

- `EventMembership`: `ROLES = %w[manager check_in viewer].freeze` + inclusion validation, mirroring `EventActivity::ACTIONS` / `Event::PLANS`. Uniqueness validation on `[event_id, user_id]` to match the index.
- `EventInvitation`: token via `SecureRandom.urlsafe_base64(32)` (matching `User#generate_email_verification_token!`), `EXPIRY = 14.days`, `pending?`/`expired?`/`accepted?`/`revoked?`, and `.find_by_valid_token` following `User.find_by_valid_email_verification_token`'s shape.
- `Event`: `has_many :event_memberships, dependent: :destroy`, `has_many :members, through: :event_memberships, source: :user`, `has_many :event_invitations, dependent: :destroy`.
- `User`: `has_many :event_memberships, dependent: :destroy`, `has_many :member_events, through: :event_memberships, source: :event`.
- Factories + model specs.

## Decision needed in this ticket

`Event#discard!` currently cascades only to registrations and waitlist entries (`event.rb:104-110`). Memberships should almost certainly be left alone — the event is soft-deleted, not gone, and undeleting shouldn't lose the team — but state it explicitly rather than leaving it to `dependent: :destroy` semantics on a soft delete.

## Acceptance criteria

- [ ] Migrations run clean; a user cannot hold two memberships on one event
- [ ] Invitation tokens are unique and expire after 14 days
- [ ] `.find_by_valid_token` returns nil for expired, revoked, and already-accepted invitations
- [ ] `Event#discard!` behaviour toward memberships is explicit and commented
BODY
create_issue "Event membership: schema and models" "$LABEL,backend,priority:high" "$_BODY_1$SPEC_NOTE"

# ── B ─────────────────────────────────────────────────────────────────────────
# bash 3.2 (macOS default) mis-parses a heredoc inside $( ), so the body is
# read into a variable at top level first rather than inline in the call.
read -r -d '' _BODY_2 <<'BODY' || true
Must land before role gating, and is worth doing on its own.

## Problem

The same authorization decision is expressed **20 times across 8 controllers**, in two different idioms with two different failure modes:

- **404-style** — `current_user.events.find(...)` rescued into `404 "Event not found"`. Used by `events#activity`, `registrations#event_registrations`, `registrations#export`, `event_plan_payments#create`/`#show`, `survey_responses#index`, `results#import`.
- **403-style** — `unless event.creator_id == current_user.id` → `403 "Forbidden"`. Used by `events#update`/`#destroy`/`#unpublish` (via `authorize_creator!`), `registrations#update`/`#destroy`/`#check_in`/`#undo_check_in`, `results#update`, `waitlist_entries#event_waitlist`, `refunds#index`/`#create` (via `find_authorized_payment`, which also allows platform admins).

The split isn't principled — it's just how each controller happened to get written. Layering a second dimension (role) onto that as-is means 20 independent chances to get a check subtly wrong, and no single place to read off who can do what.

## Scope

New `app/controllers/concerns/event_authorization.rb`, included in `Api::V1::BaseController` (currently 3 lines — `include ValidateParams` — and every controller in the list already inherits from it):

- `authorize_event!(event, :capability)` — renders on failure
- `event_role_for(event)` — `:owner` / `:manager` / `:check_in` / `:viewer` / `nil`
- `CAPABILITIES` constant — the permission matrix as data, in one place

Refactor all 20 endpoints to call it. **This ticket changes no behaviour** — with no membership rows in the database, `event_role_for` returns `:owner` or `nil` and every endpoint responds exactly as today.

Settle the 404-vs-403 split here too. Recommendation: **404 for "no relationship with this event at all"** (don't confirm existence to a stranger — matches `require_admin!`'s existing philosophy) and **403 for "you're on the team but your role can't do this"** (they already know it exists; 404 would just confuse). Existing specs asserting the current codes need updating where the two disagree.

## Acceptance criteria

- [ ] Full suite green with no membership rows present
- [ ] `grep -rn "creator_id ==\|current_user.events.find" app/controllers/api/v1/` (excluding `admin/`) returns nothing
- [ ] 404-vs-403 rule is documented in the concern
BODY
create_issue "Event membership: centralize organizer authorization (no behaviour change)" "$LABEL,backend,priority:high" "$_BODY_2$SPEC_NOTE"

# ── C ─────────────────────────────────────────────────────────────────────────
# bash 3.2 (macOS default) mis-parses a heredoc inside $( ), so the body is
# read into a variable at top level first rather than inline in the call.
read -r -d '' _BODY_3 <<'BODY' || true
**Depends on:** schema/models + centralized authorization.

## Permission matrix

| Capability | Owner | Manager | Check-in | Viewer |
|---|:--:|:--:|:--:|:--:|
| View event dashboard | ✅ | ✅ | ✅ | ✅ |
| View participant list | ✅ | ✅ | ✅ | ✅ |
| Check in / undo check-in | ✅ | ✅ | ✅ | ❌ |
| Edit event details | ✅ | ✅ | ❌ | ❌ |
| Remove participant | ✅ | ✅ | ❌ | ❌ |
| Update payment status | ✅ | ✅ | ❌ | ❌ |
| Issue refunds | ✅ | ✅ | ❌ | ❌ |
| Waitlist | ✅ | ✅ | ❌ | ✅ (read) |
| Set results | ✅ | ✅ | ❌ | ❌ |
| View survey responses | ✅ | ✅ | ❌ | ✅ |
| View activity log | ✅ | ✅ | ❌ | ✅ |
| CSV export | ✅ | ✅ | ❌ | ❌ |
| Publish / change plan | ✅ | ❌ | ❌ | ❌ |
| Unpublish | ✅ | ❌ | ❌ | ❌ |
| Delete event | ✅ | ❌ | ❌ | ❌ |
| Invite / remove / re-role members | ✅ | ❌ | ❌ | ❌ |

Three deliberate exclusions from Manager — they either spend the owner's money or change who controls the event: **plan payments** charge the owner's card, **delete/unpublish** destroy work that isn't theirs, and **member management** would let a Manager dilute the owner out of their own event with no audit trail they'd notice.

**CSV export is Manager-only, not Viewer**, even though Viewer can already page through the same participants. Bulk export is a different risk (one click, whole attendee list, off-platform) and Viewer is the role you'd hand a sponsor or board member.

## Scope

- Fill in `CAPABILITIES`; have `event_role_for` consult `EventMembership` when the user isn't the creator.
- **Extend `events#my_events`** — it currently lists `current_user.events` (events you *created*). It must also include events you're a member of, tagged with the caller's role. **This is the change most likely to be forgotten:** without it, an invited member accepts and then has no way to reach the event at all.
- Refunds: `find_authorized_payment` currently allows `organizer? || current_user.admin?`. Extend the organizer arm to Manager; leave the admin arm untouched.

## Acceptance criteria

- [ ] Request specs per role × per capability, asserting both allow and deny
- [ ] A Check-in member can check someone in but gets 403 on `events#update`, `refunds#create`, and `registrations#export`
- [ ] A member of any role sees the event in `GET /api/v1/events/my`, with their role in the payload
- [ ] Revoking a membership immediately revokes access (no token/session caching)
BODY
create_issue "Event membership: apply role-based gating" "$LABEL,backend,priority:high" "$_BODY_3$SPEC_NOTE"

# ── D ─────────────────────────────────────────────────────────────────────────
# bash 3.2 (macOS default) mis-parses a heredoc inside $( ), so the body is
# read into a variable at top level first rather than inline in the call.
read -r -d '' _BODY_4 <<'BODY' || true
**Depends on:** schema/models + centralized authorization.

## Scope

- `POST /api/v1/events/:event_id/invitations` — owner-only. Params `email`, `role`. Request schema following `ApplicationRequestSchema`, `role` inclusion-validated.
- Guard rails, each with a machine-readable `code:` per house convention (see `code: "full"`, `code: "recaptcha_failed"`, `code: "verification_required"`):
  - inviting yourself → `code: "self_invite"`
  - already a member → `code: "already_member"`
  - duplicate pending invite → `code: "invite_pending"`
- `EventInvitationMailer#invite` (html + text), following `EventMailer`'s shape, using `ApplicationMailer#frontend_url` to build `/events/:event_id/invitations/:token`. Sent with `deliver_later`.
- `GET /api/v1/events/:event_id/invitations` — owner-only, pending invites.
- `DELETE /api/v1/events/:event_id/invitations/:id` — owner-only, sets `revoked_at`.
- Log `invite_member` / `revoke_invitation` to `EventActivity`.

## Acceptance criteria

- [ ] Inviting a brand-new email sends exactly one email with a working tokenized link
- [ ] Inviting an existing member returns 422 `code: "already_member"` and sends nothing
- [ ] A revoked invitation's token no longer resolves
- [ ] Non-owners (including Managers) get 403
BODY
create_issue "Event membership: invite a member" "$LABEL,backend,priority:high" "$_BODY_4$SPEC_NOTE"

# ── E ─────────────────────────────────────────────────────────────────────────
# bash 3.2 (macOS default) mis-parses a heredoc inside $( ), so the body is
# read into a variable at top level first rather than inline in the call.
read -r -d '' _BODY_5 <<'BODY' || true
**Depends on:** invite flow.

## Scope

- `GET /api/v1/invitations/:token` — **public, unauthenticated**. Returns only enough to render the landing page (event title, inviter display name, role, still-valid?). Deliberately minimal: anyone holding the link can reach this.
- `POST /api/v1/invitations/:token/accept` — authenticated. Creates the `EventMembership`, stamps `accepted_at`, logs `member_joined`.
- Frontend route `/events/$eventId/invitations/$token`: renders the invite, sends an unauthenticated visitor through signup/signin and back (existing `_authenticated` layout redirect pattern), then calls accept.

## Decision needed: email-match policy

Simplest and safest is to require the signed-in user's email to match the invitation's, erroring `code: "invitation_email_mismatch"` otherwise.

The looser alternative — any signed-in user holding the token may accept — makes forwarded invites work, which organizers may genuinely want, but turns the link into a bearer credential. That's the exact property we rejected shareable join links for.

**Recommendation:** strict matching, with the error naming the invited address so the user knows which account to sign in with.

## Acceptance criteria

- [ ] A user with no Rally account can follow the link, sign up, and land on the event as a member
- [ ] An expired or revoked token renders a clear "this invitation is no longer valid" state, not a generic error
- [ ] Accepting twice is idempotent — no duplicate membership, no 500 from the unique index
BODY
create_issue "Event membership: accept an invitation" "$LABEL,backend,frontend,priority:high" "$_BODY_5$SPEC_NOTE"

# ── F ─────────────────────────────────────────────────────────────────────────
# bash 3.2 (macOS default) mis-parses a heredoc inside $( ), so the body is
# read into a variable at top level first rather than inline in the call.
read -r -d '' _BODY_6 <<'BODY' || true
**Depends on:** schema/models, centralized authorization, role gating.

## Scope

- `GET /api/v1/events/:event_id/members` — visible to **any member** (you should be able to see who else is on the team). Returns display name, avatar, role, joined-at.
- `PATCH /api/v1/events/:event_id/members/:id` — owner-only, changes role.
- `DELETE /api/v1/events/:event_id/members/:id` — owner-only, removes. **Also allow a member to remove themselves** (leave the event) — otherwise the only exit is asking the owner.
- The owner is not an `EventMembership` row. `#index` should synthesize them into the list as `role: "owner"` so the UI doesn't have to special-case an absent first entry.

## Acceptance criteria

- [ ] Owner can promote a Viewer to Manager and demote back
- [ ] A removed member immediately loses access to every gated endpoint
- [ ] A Manager attempting any write action gets 403
- [ ] A member can leave an event they were invited to
BODY
create_issue "Event membership: manage existing members" "$LABEL,backend,priority:medium" "$_BODY_6$SPEC_NOTE"

# ── G ─────────────────────────────────────────────────────────────────────────
# bash 3.2 (macOS default) mis-parses a heredoc inside $( ), so the body is
# read into a variable at top level first rather than inline in the call.
read -r -d '' _BODY_7 <<'BODY' || true
**Depends on:** role gating, invite flow, member management.

## Scope

- New **Members** tab on the manage-event page (`frontend/src/routes/_authenticated/dashboard_.events.$eventId.tsx`).
  - Note the `TabsList` grid columns are currently `grid-cols-7`/`grid-cols-6` behind a `ev?.survey_id` ternary (line ~771). Adding a tab makes it 8/7, and **both `max-w-*` values need widening too**.
  - Current tab order: Branding → Participants → Check-in → Results → Responses (conditional) → Certificate → Activity Logs.
- Invite form (email + role select), pending-invitations list with revoke, member list with role change and remove. Owner-only; other roles see a read-only roster.
- **Role-aware chrome throughout the page.** A Check-in member shouldn't see a Branding tab and a greyed-out Delete button — they should see the tabs their role can actually use. Drive this off the role returned by `events#my_events` / `events#show`.
  - As with `PaidEventGate`, this is an affordance, not a security boundary. The server re-checks everything.
- i18n keys in **both** `en.json` and `km.json`, in lockstep (a key missing from `km.json` silently falls back to English).

## Acceptance criteria

- [ ] Owner can complete the whole loop — invite, see pending, revoke, change role, remove — without leaving the tab
- [ ] Signing in as a Check-in member shows the Check-in and Participants tabs and nothing else
- [ ] No hardcoded user-facing strings; both locale files updated
BODY
create_issue "Event membership: Members tab and role-aware UI" "$LABEL,frontend,priority:medium" "$_BODY_7$SPEC_NOTE"

# ── H ─────────────────────────────────────────────────────────────────────────
# bash 3.2 (macOS default) mis-parses a heredoc inside $( ), so the body is
# read into a variable at top level first rather than inline in the call.
read -r -d '' _BODY_8 <<'BODY' || true
Low priority but cheap — do it alongside the invite/member tickets rather than after.

## Scope

`EventActivity::ACTIONS` is currently `%w[remove_participant update_event_details]` and is **inclusion-validated** (`event_activity.rb:22`), so `EventActivity.log!` raises on anything else. Add:

- `invite_member`
- `revoke_invitation`
- `member_joined`
- `remove_member`
- `change_member_role`

Log from the relevant controller actions with metadata (`email`, `role`, `from`/`to` for role changes). Extend the Activity Logs tab's renderer to describe the new action types.

`EventActivity` already has `belongs_to :actor, class_name: "User"` and `EventsController#event_activity_json` resolves `actor_name` from profile-or-email — so member-authored entries render correctly with **no change**. This is what makes the log genuinely useful once more than one person can act on an event.

## Acceptance criteria

- [ ] All five actions log with useful metadata
- [ ] Activity Logs tab renders each new action type in human-readable form
- [ ] Entries authored by a member (not the owner) show that member's name
BODY
create_issue "Event membership: activity logging for membership changes" "$LABEL,backend,priority:low" "$_BODY_8$SPEC_NOTE"

# ── Separate finding, not part of the feature ────────────────────────────────
# bash 3.2 (macOS default) mis-parses a heredoc inside $( ), so the body is
# read into a variable at top level first rather than inline in the call.
read -r -d '' _BODY_9 <<'BODY' || true
Found while scoping event membership. **Not part of that feature** — filing separately so it isn't lost.

## Problem

`POST /api/v1/uploads` (`app/controllers/api/v1/uploads_controller.rb`) is gated only by `before_action :authenticate_user!` (line 4). There is **no ownership or event-scoping check at all** — any signed-in account can upload a banner, logo, or certificate template and receive a blob URL back.

Attaching an upload to an event *is* creator-gated (it goes through `events#update`), so this is **not** currently an event-takeover path. But it is:

- an unmetered storage-cost vector — any account can fill the S3 bucket
- a content-hosting vector — arbitrary files served from Rally's own domain/CDN

The content-type and size validation in the controller limits *what* can be uploaded, but not *how much* or *by whom*.

## Suggested scope

- Rate-limit uploads per user (`rack-attack` is already configured — `config/initializers/rack_attack.rb`)
- Consider scoping uploads to an event the caller can actually edit, or tracking orphaned blobs for cleanup
- Consider a per-account storage quota

Worth confirming the current Active Storage retention/cleanup story at the same time — orphaned blobs from abandoned event drafts may already be accumulating.
BODY
create_issue "UploadsController has no ownership check" "backend,security,priority:medium" "$_BODY_9$SPEC_NOTE"

# ── Summary ───────────────────────────────────────────────────────────────────
echo
if $DRY_RUN; then
  echo "Dry run complete — nothing was created."
  echo "Re-run without --dry-run to create them for real."
else
  echo "Done. Created ${#created_urls[@]} issue(s)."
  if [[ -z "$PROJECT" ]]; then
    echo
    echo "To add them to a project board, find its number with:"
    echo "    gh project list --owner ${REPO%%/*}"
    echo "then re-run with --project <number> (already-created issues are skipped,"
    echo "so it's safe to run again purely to do the board step)."
  fi
fi
