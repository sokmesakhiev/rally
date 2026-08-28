#!/usr/bin/env bash
#
# Creates the ten organizer-identity tickets from organization-identity-tickets.md
# as GitHub issues on sokmesakhiev/rally, and (optionally) adds them to a project board.
#
# Written to be run by you, not by CI — it needs your own `gh` auth.
#
#   Prerequisites:  gh auth login          (one-off, if you haven't already)
#   Dry run:        ./scripts/create-organization-issues.sh --dry-run
#   For real:       ./scripts/create-organization-issues.sh
#   With a board:   ./scripts/create-organization-issues.sh --project 3
#
# --dry-run prints every issue it would create without touching GitHub. Run that
# first — this script creates ten issues, and un-creating them is manual.
#
# Idempotency: re-running WILL create duplicates. It checks for an existing open
# issue with the same title first and skips it, but that check is title-exact —
# if you edit a title on GitHub, the next run recreates it.

set -euo pipefail

REPO="sokmesakhiev/rally"
LABEL="organization-identity"
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

ensure_label "$LABEL"          "0052CC" "Organizer identity / organizations feature"
ensure_label "backend"         "1D76DB" "Rails API"
ensure_label "frontend"        "5319E7" "TanStack Start app"
ensure_label "priority:high"   "B60205" "Blocking or foundational"
ensure_label "priority:medium" "FBCA04" "Normal"
ensure_label "priority:low"    "0E8A16" "Nice to have"
ensure_label "security"        "D93F0B" "Security-relevant"
ensure_label "data-migration"  "C2E0C6" "Involves backfilling or moving existing data"

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

SPEC_NOTE=$'\n\n---\nFull scoping doc, including the sequencing graph and open questions: `organization-identity-tickets.md` in the repo root.'

# ── A ─────────────────────────────────────────────────────────────────────────
# bash 3.2 (macOS default) mis-parses a heredoc inside $( ), so the body is
# read into a variable at top level first rather than inline in the call.
read -r -d '' _BODY_A <<'BODY' || true
Foundational ticket for organizer identity — every other ticket in this series depends on it.

## Scope

Two tables, plus a backfill of existing data.

**`organizations`**

| Column | Type | Notes |
|---|---|---|
| `owner_id` | uuid, null: false | FK to users. See below. |
| `name` | string, null: false | Public display name |
| `slug` | string, null: false, unique | URL identity: `/organizers/phnom-penh-runners` |
| `description` | text | Bio, shown on the public page |
| `logo_url` / `banner_url` | string | |
| `brand_color` | string | Same format as `Event#brand_color` |
| `website` | string | |
| `contact_email` / `contact_phone` | string | Public — deliberately separate from the account login email |
| `facebook_url` / `instagram_url` / `telegram_url` | string | |
| `verified_at` | datetime | Populated by #I |
| `deleted_at` | datetime | Soft-delete, matching Event's existing discard pattern |

**Ownership is a column, not a role.** `organizations.owner_id` is the single source of truth. This makes "exactly one owner" a structural guarantee rather than an invariant some validation has to defend, and it gives the suspension cascade (#J) a cheap `belongs_to :owner` instead of a join through membership rows.

**`organization_memberships`** — `organization_id`, `user_id`, `role`, unique on the pair. Holds **`admin` and `member` only**; the owner is never a membership row. Member-listing endpoints and UI union the owner with the membership rows so the team reads as one list.

- `admin` — everything except deleting the org and transferring ownership
- `member` — can be added to individual events by the org's admins, but has no org-wide event authority on its own

`slug` is generated from `name` on create, uniqueness-checked with a numeric suffix on collision, and **immutable afterwards** — a public URL that changes silently breaks every link an organizer has already shared. Renaming changes `name`, never `slug`.

> Deliberately distinct from `EventMembership`. Org membership answers "can you act on behalf of this organization"; event membership answers "can you help run this specific event". A volunteer gets an `EventMembership` with role `check_in` on one race and no org membership at all. Do not merge these.

**A user may own and belong to any number of organizations.** Someone can run their own race series and also be an admin of a club they volunteer for. No caps, no "primary organization".

## Backfill

For every `User` who owns at least one `Event`, create an `Organization` with `owner_id` set to them, named from `Profile#display_name` (falling back to the email local-part), with a generated slug. Copy `Profile#avatar_url` into `logo_url` as a starting point. Write it idempotent and re-runnable.

## Acceptance criteria

- [ ] `Organization` and `OrganizationMembership` models exist with validations, and `Organization` has `#owner`, `#admins`, `#administered_by?(user)`, `#member?(user)`
- [ ] Slug generation handles collisions and is immutable after create
- [ ] Backfill creates exactly one organization per event-owning user and is safe to run twice
- [ ] Users with no events get no organization (they're participants, not organizers)
- [ ] A user can own several organizations and be an admin of others simultaneously
- [ ] Specs cover slug collision, immutability, the owner-is-not-a-membership-row rule, and the backfill
BODY

create_issue "Organizations: model, membership, and backfill" \
  "$LABEL,backend,priority:high,data-migration" "${_BODY_A}${SPEC_NOTE}"

# ── B ─────────────────────────────────────────────────────────────────────────
read -r -d '' _BODY_B <<'BODY' || true
Blocked by: Organizations model (#A)

## Why

`AbaPayway::Client.for_event` currently reads `event.creator&.profile` to decide whose PayWay credentials take an attendee's registration payment. Once events belong to organizations, the money has to follow the organization — not whichever individual happened to click Create.

## Scope

Add `payway_merchant_id`, `payway_api_key` (encrypted), `payway_rsa_public_key` to `organizations`, carrying over `Profile`'s existing validation shape verbatim:

- both-or-neither for merchant_id/api_key
- blanks nilified
- `#payway_configured?`, `#payway_refund_configured?`, `#payway_api_key_masked`

Migrate existing values from each `Profile` to that user's backfilled organization, then **remove the columns from `profiles`** — leaving two live copies of a payment credential is how you end up paying the wrong account.

Update `AbaPayway::Client.for_event` to read `event.organization`. Everything else about that method — the fallback to Rally's platform account, the RSA key nil-handling and its explanatory comment — stays exactly as written.

## Acceptance criteria

- [ ] Registration payments route through the event's organization's credentials when configured, Rally's platform account when not
- [ ] `EventPlanPayment` (organizer → Rally) still always uses `Client.new` with no args — unchanged
- [ ] Existing organizer credentials survive the migration and keep working
- [ ] `payway_api_key` is still encrypted at rest and never returned in plaintext
- [ ] `ProfilesController#profile_json` no longer exposes PayWay fields; the organization endpoint does
- [ ] Payment specs updated; `AbaPayway::Client` specs cover the org-credential path
BODY

create_issue "Move PayWay credentials from Profile to Organization" \
  "$LABEL,backend,priority:high,security,data-migration" "${_BODY_B}${SPEC_NOTE}"

# ── C ─────────────────────────────────────────────────────────────────────────
read -r -d '' _BODY_C <<'BODY' || true
Blocked by: PayWay credential move (#B)

## Scope

Add `organization_id` to `events` (null: false after backfill). **`creator_id` stays** — it's still useful to know which human created the event, and the activity log references it.

Extend `EventAuthorization#event_role_for`:

```ruby
return :owner if event.creator_id == current_user.id
return :owner if event.organization.administered_by?(current_user)   # owner or admin
# then the existing EventMembership lookup, unchanged
```

An org `member` gets nothing here — they need an explicit `EventMembership` like anyone else. The `CAPABILITIES` matrix itself doesn't change at all; this only widens who resolves to `:owner`.

**`organization_id` is a required parameter on `EventsController#create`,** rejected unless the current user owns or administers that org. Because a user may belong to many organizations, the server never infers which one — guessing wrong would publish an event under the wrong brand, which is precisely the failure this whole feature exists to prevent.

`events#my_events` widens to include every event belonging to any org the user owns or administers, in addition to events they personally created or hold an `EventMembership` on.

## Acceptance criteria

- [ ] An org admin can fully manage events created by a colleague in the same org
- [ ] An org `member` with no `EventMembership` gets no access — same as a stranger
- [ ] Creating an event without `organization_id`, or for an org you don't administer, is rejected
- [ ] A user belonging to several orgs sees all their events in `my_events`, with no duplicates
- [ ] The suspended-event lockdown still overrides org role, exactly as it overrides `:owner` today
- [ ] Existing per-event `EventMembership` roles behave identically to before
- [ ] Concern specs extended for the org-role matrix
BODY

create_issue "Events belong to an organization, with org-aware authorization" \
  "$LABEL,backend,priority:high,security" "${_BODY_C}${SPEC_NOTE}"

# ── D ─────────────────────────────────────────────────────────────────────────
read -r -d '' _BODY_D <<'BODY' || true
Blocked by: Events belong to an organization (#C)

## Scope

- `GET/POST/PATCH /api/v1/organizations`
- `GET /api/v1/organizations/:slug`
- Member management mirroring the existing `event_members` shape (`index`/`update`/`destroy`), self-removal allowed

Branding uploads go through the **existing** `Api::V1::UploadsController` — it already validates content-type and size and stores via Active Storage. Do not add a second upload path.

Ownership transfer is its own endpoint, owner-only, and updates `organizations.owner_id`.

## Acceptance criteria

- [ ] Organizers can create and edit their org, upload logo/banner, set brand color and all identity fields
- [ ] Only owner/admin may edit; only owner may delete or transfer ownership
- [ ] The owner cannot leave their own org without first transferring ownership
- [ ] `contact_email` is validated as an email; `website` and social URLs validated as http(s)
- [ ] Request specs cover the role matrix and the ownership-transfer guards
BODY

create_issue "Organization management API (CRUD, members, branding uploads)" \
  "$LABEL,backend,priority:high" "${_BODY_D}${SPEC_NOTE}"

# ── E ─────────────────────────────────────────────────────────────────────────
read -r -d '' _BODY_E <<'BODY' || true
Blocked by: Events belong to an organization (#C)

## Scope

Publishing any event — free or paid — requires the owning organization to have **name, logo, description, and at least one contact method** (email or phone).

Enforce server-side in the publish path. `EventPlanPayment#mark_paid!` (paid plans) and the free-tier publish path both funnel through `Event`'s publish logic — **gate it there, not in the controller**, so neither route can bypass it.

Return a machine-readable `code: "organization_incomplete"` with the list of missing fields, following the existing `code: "full"` / `code: "terms_not_accepted"` precedent.

> **Ordering matters.** This check must run *before* any payment is attempted, exactly as `Event#capacity_covers_event_types` already does. Taking an organizer's money and then refusing to publish is the one outcome to avoid.

## Acceptance criteria

- [ ] Publishing with an incomplete org is rejected before payment, with the missing fields named
- [ ] Both the free-tier and paid-plan publish paths are gated
- [ ] Already-published events are unaffected (no retroactive unpublishing)
- [ ] Specs cover each missing-field combination and the before-payment ordering
BODY

create_issue "Require a complete organization identity to publish an event" \
  "$LABEL,backend,priority:medium" "${_BODY_E}${SPEC_NOTE}"

# ── F ─────────────────────────────────────────────────────────────────────────
read -r -d '' _BODY_F <<'BODY' || true
Blocked by: Organization management API (#D) and cascading suspension (#J)

> **Ship #J first.** Until the suspension cascade exists, this endpoint is a public surface that can display an organization Rally has already decided to suspend.

## Scope

`GET /api/v1/organizations/:slug` — public, no auth required. Returns:

- Identity and branding
- Contact and social links
- Published upcoming events, optionally past events
- Trust signals:
  - **Member since** — `created_at`
  - **Events run** — count of published, ended events
  - **Participants hosted** — sum of confirmed registrations across those events

Compute trust signals with **database aggregates, not by loading records**. They're read on every public page view, so they want to be cheap — a counter-cache or cached count is fine, an N+1 across registrations is not.

## Acceptance criteria

- [ ] Anonymous visitors can fetch an organization by slug
- [ ] Only published, non-suspended, non-discarded events are listed
- [ ] Suspended organizations return 404
- [ ] Trust signals are accurate and computed in aggregate
- [ ] A private-field leak test asserts the payload contains no PayWay data and no account login email
- [ ] Unknown slug returns 404
BODY

create_issue "Public organizer page API (identity, events, trust signals)" \
  "$LABEL,backend,priority:medium,security" "${_BODY_F}${SPEC_NOTE}"

# ── G ─────────────────────────────────────────────────────────────────────────
read -r -d '' _BODY_G <<'BODY' || true
Blocked by: Require complete organization identity (#E)

## Scope

A new organization settings area: identity fields, branding uploads with live preview, contact and social links, member management, and PayWay payment settings (moved here from the personal profile page).

The existing profile page keeps personal account concerns — display name, avatar, password, email, notification preferences. Payment settings move out, so update `SiteHeader`'s dropdown deep-link accordingly.

### Multi-org UI

Since a user may own or administer several organizations:

- An **org switcher** in the settings area and in `SiteHeader`
- The **create-event form takes an explicit organization selector**, defaulting to the last-used org (remembered client-side) but never silently choosing when the user has more than one. With exactly one org, render it as a non-interactive label rather than a dropdown — no decision to make.
- The dashboard event list shows which org each event belongs to, and can filter by org
- A user with no organization yet is prompted to create one the first time they try to create an event

Show a clear completeness indicator: which fields are still missing before this org can publish (#E), so an organizer finds out here rather than at the moment they try to publish.

## Acceptance criteria

- [ ] An organizer can complete their whole identity in one place, per organization
- [ ] Switching orgs swaps the whole settings context, including payment settings
- [ ] Creating an event with several orgs available always requires an explicit choice
- [ ] Uploads preview before saving
- [ ] Non-admin org members see a read-only view
- [ ] The publish-readiness checklist reflects #E's exact requirements
- [ ] All strings via `t()`, `en.json` and `km.json` in lockstep
BODY

create_issue "Frontend: organization settings, branding, and org switcher" \
  "$LABEL,frontend,priority:medium" "${_BODY_G}${SPEC_NOTE}"

# ── H ─────────────────────────────────────────────────────────────────────────
read -r -d '' _BODY_H <<'BODY' || true
Blocked by: Public organizer page API (#F)

## Scope

New public route `/organizers/$slug` rendering the #F payload: banner, logo, name, verified badge, description, trust signals, contact/social links, and their events.

On the event detail page, add a **"Presented by"** block — org logo, name, verified badge, linking to the organizer page. This sits **distinctly from the event's own hero branding**: per the up-front decision, event branding and org branding are both shown, in different places, with no inheritance and no override. Add the same, more compactly, to event cards in listings.

### Participants reach organizer pages too

A registrant's own dashboard links each of their registrations to the presenting organization, so someone deciding whether to sign up for a second event can check who's behind it.

The **verified badge is the load-bearing trust signal** — it should be visually prominent and consistent everywhere an org appears (organizer page, "Presented by" block, event cards, registration list), and unmistakably distinct from an unverified org rather than merely absent.

## Acceptance criteria

- [ ] The organizer page renders correctly with the brand color applied, and degrades gracefully when logo/banner/socials are absent
- [ ] The event page's "Presented by" block never visually competes with the event's own banner
- [ ] The verified badge renders identically across all four surfaces; unverified orgs are visibly unverified, not just missing a badge
- [ ] Participants can navigate from a registration to the presenting organization
- [ ] Page has proper `head()` meta for link previews (English only, per the existing convention that route meta isn't translated)
- [ ] Works for anonymous visitors
BODY

create_issue "Frontend: public organizer page and Presented-by block" \
  "$LABEL,frontend,priority:medium" "${_BODY_H}${SPEC_NOTE}"

# ── I ─────────────────────────────────────────────────────────────────────────
read -r -d '' _BODY_I <<'BODY' || true
Blocked by: Events belong to an organization (#C)

## Why

Verification is a claim about *who is taking the money* — which is now the organization, not the individual who clicked Create.

## Scope

Add `Organization#verified_at`, `#verified?`, `#verify!`/`#unverify!`, mirroring `User`'s existing methods exactly.

Add admin endpoints `POST /admin/organizations/:id/verify` and `/unverify`, logging to `AdminAction` like every other admin action. Add an Organizations tab to the admin console.

Switch the paid-event gate from `User#verified?` to `Organization#verified?`.

**Backfill:** any organization whose owner is currently verified becomes verified, so no existing organizer loses the ability to run paid events at deploy.

> Keep `User#verified?` and its admin endpoints in place for one release rather than deleting them in the same change. The paid-event gate is load-bearing, and a bug here silently blocks organizers from taking money.

## Acceptance criteria

- [ ] Paid events are gated on organization verification
- [ ] The backfill leaves every currently-verified organizer able to publish paid events
- [ ] Verified badge appears on the public organizer page and the "Presented by" block
- [ ] Admin can verify/unverify an org; the action is in the audit trail
- [ ] Specs cover the gate, the backfill, and the admin endpoints
BODY

create_issue "Move organizer verification from User to Organization" \
  "$LABEL,backend,priority:medium,data-migration" "${_BODY_I}${SPEC_NOTE}"

# ── J ─────────────────────────────────────────────────────────────────────────
read -r -d '' _BODY_J <<'BODY' || true
Blocked by: Events belong to an organization (#C)
Blocks: Public organizer page API (#F)

Suspending an organization must take down every event it presents, and suspending a user must take down every organization they **own**.

> **Only owned organizations cascade.** A user who is merely an `admin` of a club loses their own access when suspended (they can't sign in), but the club and its events are untouched. Cascading through admin membership would let one bad actor take down a legitimate organization they happened to volunteer for.

## Design: derive, don't copy

Suspension state is **computed downward**, never written downward:

```ruby
# Organization
def suspended? = suspended_at.present? || owner.suspended?

# Event
def suspended? = suspended_at.present? || organization.suspended?
```

This is why `organizations.owner_id` is a real column (#A) — the chain is two `belongs_to` hops, preloadable with `includes(organization: :owner)`, not a join through membership rows.

Deriving rather than copying is what makes **unsuspend automatically correct**, which is the part that's easy to get wrong. Lifting an org's suspension instantly restores exactly the events that went down with it, while any event *also* suspended directly on its own merits stays suspended, because its own `suspended_at` is still set. No provenance column, no reconciliation job, no possibility of org and event state drifting apart.

## Two behaviours to keep straight

| | Direct event suspension | Cascade (org or owner suspended) |
|---|---|---|
| Sets `events.suspended_at` | Yes | No — derived |
| Unpublishes the event | Yes | No |
| Reversing it restores the event | No — organizer republishes | **Yes, automatically** |

The asymmetry is deliberate. Directly suspending an event is a judgment about *that event*. Cascade suspension is a judgment about the *organization*, so lifting it should undo it wholesale — an organizer cleared on appeal shouldn't have to republish fifty events, and for paid plans republishing would route back through the payment flow.

## Existing behaviour that must change

`User#suspend!` currently does `events.published.update_all(is_published: false)`. **Remove that.** With derivation it's redundant for hiding events, and now actively wrong: it would leave events unpublished after an unsuspend, contradicting the automatic-restore behaviour above. Its spec and doc comment both need updating — the comment explicitly documents the old republishing rule.

## Query surface

Every public-facing query needs to exclude cascade-suspended events:

```ruby
scope :from_active_organizations, -> {
  joins(organization: :owner)
    .where(organizations: { suspended_at: nil }, users: { suspended_at: nil })
}
```

Apply to the public events listing, search, sitemap, and the organizer page's event list. **Audit every existing `Event.published` call site** — missing one means a suspended organizer's event stays publicly visible, the exact failure this ticket exists to prevent.

## Admin surface

`POST /admin/organizations/:id/suspend` (reason required) and `/unsuspend`, mirroring the event endpoints exactly: `AdminAction` audit entries, and an email to the org owner stating the reason, including the org name, slug, and a link so they can appeal.

## Acceptance criteria

- [ ] Suspending an org hides all its events publicly and locks its team out of mutating them
- [ ] Suspending a user cascades to orgs they own, and **not** to orgs they merely administer
- [ ] Unsuspending an org restores its events automatically
- [ ] An event suspended directly **stays suspended** after its org is unsuspended
- [ ] `User#suspend!` no longer unpublishes events; its spec and comment are updated
- [ ] Read-only access survives a cascade, exactly as it does for direct event suspension
- [ ] The UI distinguishes *why* something is unavailable: "this event was suspended" vs "this organizer has been suspended"
- [ ] Every `Event.published` call site is audited and scoped
- [ ] Suspended orgs 404 on the public organizer page
- [ ] Specs cover the full matrix: direct-only, cascade-only, both at once, and each unsuspend path
BODY

create_issue "Cascading suspension: user to organization to events" \
  "$LABEL,backend,priority:high,security" "${_BODY_J}${SPEC_NOTE}"

# ── Summary ───────────────────────────────────────────────────────────────────
echo
if $DRY_RUN; then
  echo "Dry run complete — nothing was created."
  echo "Re-run without --dry-run to create them for real."
else
  echo "Done. Created ${#created_urls[@]} issue(s)."
  if [[ ${#created_urls[@]} -gt 0 ]]; then
    printf '  %s\n' "${created_urls[@]}"
  fi
  echo
  echo "Suggested order: A → B → C, then D/E/I/J in parallel, F after D+J, G after E, H after F."
fi
