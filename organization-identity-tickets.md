# Organizer identity & organizations — tickets

Scoped 2026-08-28 after auditing the request against the current codebase.

**The ask:** events should be presented by an *organization*, not an individual person. Each organization carries its own branding (logo, banner, color theme) and public identity, so an audience member looking at an event can click through to see who's behind it, what else they run, and how to reach them.

**Decisions taken up front** (answered before scoping, so the tickets below assume them):

1. **A separate `Organization` entity**, not enriched `Profile` fields. Users belong to organizations; events belong to an organization. This is the heavier option, chosen deliberately so a running club with several staff can share one identity, and one person can run two distinct race brands.
2. **Both brandings shown, in different places.** Per-event `banner_url`/`logo_url`/`brand_color` stay exactly as they are and keep owning the event page hero. Organization branding appears in a distinct "Presented by" block and on the organization's own public page. **No inheritance, no override logic** — the two never compete for the same slot.
3. **Full public organizer page**: identity + branding, their events, contact & social links, and trust signals (member since, events run, participants hosted).
4. **A complete organization identity is required to publish any event**, free or paid — not just paid ones. This is the strongest trust signal and it's the point of the feature; a public event with a hollow organizer defeats it.
5. **A user may own and belong to many organizations.** People genuinely work with several at once — their own race series plus a club they volunteer for. No caps, no "primary org", and event creation always asks which one explicitly.
6. **Suspension cascades downward and lifts automatically.** Suspending a user suspends the organizations they own; suspending an organization suspends its events. Unsuspending restores what the cascade took down, while anything suspended directly on its own merits stays down. See Ticket J.

---

## What this touches that isn't obvious

Three existing pieces assume "the organizer is the event's creator, a `User`". Each has to move to the organization, and each is easy to miss:

- **`AbaPayway::Client.for_event`** reads `event.creator&.profile` to decide whose PayWay credentials take an attendee's registration payment. If events belong to organizations, the money has to follow the organization, not whichever individual happened to click Create. **PayWay credentials move from `Profile` to `Organization`.**
- **`EventAuthorization#event_role_for`** resolves `:owner` via `event.creator_id == current_user.id`. Everyone on an organization with a sufficient org role needs owner-level access to that org's events, or a club's second admin can't manage events their colleague created.
- **`User#verified?`** currently gates creating paid events. Verification is a statement about *who is taking the money*, which is now the organization. See Ticket I — this moves, with a deliberate transition period.

Existing data also has to land somewhere: every current event has a `creator_id` and no organization. Ticket A backfills one organization per user who owns events.

---

## Ticket A — `Organization` model, membership, and backfill

Create the two tables and get existing data onto them, changing no behaviour yet.

**`organizations`**

| Column | Type | Notes |
|---|---|---|
| `name` | string, null: false | Public display name |
| `slug` | string, null: false, unique | URL identity: `/organizers/phnom-penh-runners` |
| `description` | text | Bio / about, shown on the public page |
| `logo_url` | string | |
| `banner_url` | string | |
| `brand_color` | string | Same format as `Event#brand_color` |
| `website` | string | |
| `contact_email` | string | Public — deliberately separate from the account's login email |
| `contact_phone` | string | |
| `facebook_url` / `instagram_url` / `telegram_url` | string | |
| `verified_at` | datetime | See Ticket I |
| `deleted_at` | datetime | Soft-delete, matching `Event`'s existing discard pattern |

`slug` is generated from `name` on create, uniqueness-checked with a numeric suffix on collision, and **immutable afterwards** — a public URL that changes silently breaks every link an organizer has already shared. Renaming the org changes `name`, never `slug`.

**Ownership is a column, not a role.** `organizations.owner_id` (FK to `users`, null: false) is the single source of truth for who owns the org. This is deliberate: it makes "exactly one owner" a structural guarantee rather than an invariant some validation has to defend, and it gives the suspension cascade in Ticket J a cheap `belongs_to :owner` instead of a join through memberships on a hot path.

**`organization_memberships`** — `organization_id`, `user_id`, `role`, unique on the pair. Holds **`admin` and `member` only**; the owner is never a membership row.

- `owner` (the column) — full control including payment settings, deleting the org, and transferring ownership.
- `admin` — everything except deleting the org and transferring ownership.
- `member` — can be added to individual events by the org's admins, but has no org-wide event authority on its own.

Member-listing endpoints and UI union the owner with the membership rows so the team reads as one list.

**A user may own and belong to any number of organizations.** Someone can run their own race series and also be an admin of a club they volunteer for. Nothing is capped, and no "primary organization" concept exists — see Ticket C for how event creation picks one.

> **Deliberately distinct from `EventMembership`.** Org membership answers "can you act on behalf of this organization"; event membership answers "can you help run this specific event". A volunteer gets `EventMembership` with role `check_in` on one race and no org membership at all. Do not merge these.

**Backfill migration:** for every `User` who owns at least one `Event`, create an `Organization` with `owner_id` set to them, named from their `Profile#display_name` (falling back to the email local-part), with a generated slug. Copy `Profile#avatar_url` into `logo_url` as a starting point. This is a data migration — write it to be idempotent and re-runnable.

**Acceptance criteria**

- `Organization` and `OrganizationMembership` models exist with validations, and `Organization` has `#owner`, `#admins`, `#administered_by?(user)`, `#member?(user)`.
- Slug generation handles collisions and is immutable after create.
- Backfill creates exactly one organization per event-owning user and is safe to run twice.
- Users with no events get no organization (they're participants, not organizers).
- A user can own several organizations and be an admin of others simultaneously.
- Specs cover slug collision, immutability, the owner-is-not-a-membership-row rule, and the backfill.

---

## Ticket B — Move PayWay credentials from `Profile` to `Organization`

Add `payway_merchant_id`, `payway_api_key` (encrypted), `payway_rsa_public_key` to `organizations`, carrying over `Profile`'s existing validation shape verbatim: both-or-neither for merchant_id/api_key, blanks nilified, `#payway_configured?`, `#payway_refund_configured?`, `#payway_api_key_masked`.

Migrate existing values from each `Profile` to that user's backfilled organization. Then **remove the columns from `profiles`** — leaving two live copies of a payment credential is how you end up paying the wrong account.

Update `AbaPayway::Client.for_event` to read `event.organization` instead of `event.creator&.profile`. Everything else about that method — the fallback to Rally's platform account, the RSA key nil-handling and its comment — stays exactly as written.

**Acceptance criteria**

- Registration payments route through the event's organization's credentials when configured, Rally's platform account when not.
- `EventPlanPayment` (organizer → Rally) still always uses `Client.new` with no args. Unchanged.
- Existing organizer credentials survive the migration and keep working.
- `payway_api_key` is still encrypted at rest and never returned in plaintext.
- `ProfilesController#profile_json` no longer exposes PayWay fields; the organization endpoint does.
- Payment specs updated; `AbaPayway::Client` specs cover the org-credential path.

---

## Ticket C — `Event belongs_to :organization` + org-aware authorization

Add `organization_id` to `events` (null: false after backfill). `creator_id` **stays** — it's still useful to know which human created the event, and the activity log references it.

Extend `EventAuthorization#event_role_for`:

```
return :owner if event.creator_id == current_user.id
return :owner if org_role_for(event.organization) in [:owner, :admin]
# then the existing EventMembership lookup, unchanged
```

An org `member` gets nothing here — they need an explicit `EventMembership` like anyone else. The `CAPABILITIES` matrix itself doesn't change at all; this only widens who resolves to `:owner`.

**`organization_id` is a required parameter on `EventsController#create`,** rejected unless the current user owns or administers that org. Because a user may belong to many organizations (see Ticket A), the server never infers which one — guessing wrong would publish an event under the wrong brand, which is precisely the failure this whole feature exists to prevent. The frontend always sends an explicit choice (Ticket G).

`events#my_events` widens to include every event belonging to any org the user owns or administers, in addition to events they personally created or hold an `EventMembership` on.

**Acceptance criteria**

- An org admin can fully manage events created by a colleague in the same org.
- An org `member` with no `EventMembership` gets no access — same as a stranger.
- Creating an event without `organization_id`, or for an org you don't administer, is rejected.
- A user belonging to several orgs sees all their events in `my_events`, with no duplicates.
- The suspended-event lockdown still overrides org role, exactly as it overrides `:owner` today.
- Existing per-event `EventMembership` roles behave identically to before.
- Concern specs extended for the org-role matrix.

---

## Ticket D — Organization management API

`GET/POST/PATCH /api/v1/organizations`, `GET /api/v1/organizations/:slug`, plus member management mirroring the existing `event_members` shape (`index`/`update`/`destroy`, self-removal allowed, last owner cannot leave or be removed).

Branding uploads go through the **existing** `Api::V1::UploadsController` — it already validates content-type and size and stores via Active Storage. Do not add a second upload path.

**Acceptance criteria**

- Organizers can create and edit their org, upload logo/banner, set brand color and all identity fields.
- Only owner/admin may edit; only owner may delete or transfer ownership.
- The last remaining owner cannot leave or be demoted.
- `contact_email` is validated as an email; `website` and social URLs validated as http(s).
- Request specs cover the role matrix and the last-owner guards.

---

## Ticket E — Require a complete organization identity to publish

Publishing any event — free or paid — requires the owning organization to have **name, logo, description, and at least one contact method** (email or phone).

Enforced server-side in the publish path (`EventPlanPayment#mark_paid!` for paid plans and the free-tier publish path both funnel through `Event`'s publish logic — gate it there, not in the controller, so neither route can bypass it). Returns a machine-readable `code: "organization_incomplete"` with the list of missing fields, following the existing `code: "full"` / `code: "terms_not_accepted"` precedent.

> Note the ordering interaction: this check must run **before** any payment is attempted, exactly as `Event#capacity_covers_event_types` already does. Taking an organizer's money and then refusing to publish is the one outcome to avoid.

**Acceptance criteria**

- Publishing with an incomplete org is rejected before payment, with the missing fields named.
- Both the free-tier and paid-plan publish paths are gated.
- Already-published events are unaffected (no retroactive unpublishing).
- Specs cover each missing-field combination and the before-payment ordering.

---

## Ticket F — Public organizer page API

`GET /api/v1/organizations/:slug` — public, no auth required. Returns identity and branding, contact and social links, published upcoming events, optionally past events, and trust signals:

- **Member since** — `created_at`
- **Events run** — count of published, ended events
- **Participants hosted** — sum of confirmed registrations across those events

Compute the trust signals with database aggregates, not by loading records. They're read on every public page view, so they want to be cheap — a counter-cache or a cached count is fine, an N+1 across registrations is not.

Suspended organizations and suspended events never appear. The endpoint must expose nothing private: no login email, no phone unless explicitly set as the public `contact_phone`, and never any PayWay field.

**Acceptance criteria**

- Anonymous visitors can fetch an organization by slug.
- Only published, non-suspended, non-discarded events are listed.
- Trust signals are accurate and computed in aggregate.
- A private-field leak test asserts the payload contains no PayWay or account-email data.
- Unknown slug returns 404.

---

## Ticket G — Frontend: organization settings

A new organization settings area: identity fields, branding uploads with live preview, contact and social links, member management, and PayWay payment settings (moved here from the personal profile page).

The existing profile page keeps personal account concerns — display name, avatar, password, email, notification preferences. Payment settings move out, so update `SiteHeader`'s dropdown deep-link accordingly.

**Multi-org UI.** Since a user may own or administer several organizations:

- An **org switcher** in the settings area and in `SiteHeader`, listing every org the user owns or administers.
- The **create-event form takes an explicit organization selector**, defaulting to the last-used org (remembered client-side) but never silently choosing when the user has more than one. If they have exactly one, render it as a non-interactive label rather than a dropdown — no decision to make.
- The dashboard event list shows which org each event belongs to, and can filter by org.
- A user with no organization yet is prompted to create one the first time they try to create an event.

Show a clear completeness indicator: which fields are still missing before this org can publish (Ticket E), so an organizer finds out here rather than at the moment they try to publish.

**Acceptance criteria**

- An organizer can complete their whole identity in one place, per organization.
- Switching orgs swaps the whole settings context, including payment settings.
- Creating an event with several orgs available always requires an explicit choice.
- Uploads preview before saving.
- Non-admin org members see a read-only view.
- The publish-readiness checklist reflects Ticket E's exact requirements.
- All strings via `t()`, `en.json` and `km.json` in lockstep.

---

## Ticket H — Frontend: public organizer page + "Presented by" on events

New public route `/organizers/$slug` rendering the Ticket F payload: banner, logo, name, verified badge, description, trust signals, contact/social links, and their events.

On the event detail page, add a **"Presented by"** block — org logo, name, verified badge, linking to the organizer page. This sits distinctly from the event's own hero branding, per the up-front decision. Add the same, more compactly, to event cards in listings.

**Participants reach organizer pages too.** A registrant's own dashboard links each of their registrations to the presenting organization, so someone deciding whether to sign up for a second event can check who's behind it. The **verified badge is the load-bearing trust signal here** — it should be visually prominent and consistent everywhere an org appears (organizer page, "Presented by" block, event cards, registration list), and unmistakably distinct from an unverified org rather than merely absent.

**Acceptance criteria**

- The organizer page renders correctly with the brand color applied, and degrades gracefully when logo/banner/socials are absent.
- The event page's "Presented by" block never visually competes with the event's own banner.
- The verified badge renders identically across all four surfaces, and unverified orgs are visibly unverified, not just missing a badge.
- Participants can navigate from a registration to the presenting organization.
- Page has proper `head()` meta for link previews (English only, per the existing convention that route meta isn't translated).
- Works for anonymous visitors.

---

## Ticket I — Move organizer verification to the organization

Verification is a claim about who takes the money — now the organization. Add `Organization#verified_at`, `#verified?`, `#verify!`/`#unverify!`, mirroring `User`'s existing methods exactly.

Add admin endpoints `POST /admin/organizations/:id/verify` and `/unverify`, logging to `AdminAction` like every other admin action. Add an Organizations tab to the admin console.

Switch the paid-event gate from `User#verified?` to `Organization#verified?`. **Backfill:** any organization whose owner is currently verified becomes verified, so no existing organizer loses the ability to run paid events at deploy.

Keep `User#verified?` and its admin endpoints in place for one release rather than deleting them in the same change — the paid-event gate is load-bearing, and a bug here silently blocks organizers from taking money.

**Acceptance criteria**

- Paid events are gated on organization verification.
- The backfill leaves every currently-verified organizer able to publish paid events.
- Verified badge appears on the public organizer page and the "Presented by" block.
- Admin can verify/unverify an org; the action is in the audit trail.
- Specs cover the gate, the backfill, and the admin endpoints.

---

## Ticket J — Cascading suspension (user → organization → events)

Suspending an organization must take down every event it presents, and suspending a user must take down every organization they **own**.

> **Only owned organizations cascade.** A user who is merely an `admin` of a club loses their own access when suspended (they can't sign in), but the club and its events are untouched. Cascading through admin membership would let one bad actor take down a legitimate organization they happened to volunteer for.

### Design: derive, don't copy

Suspension state is **computed downward**, never written downward:

```ruby
# Organization
def suspended? = suspended_at.present? || owner.suspended?

# Event
def suspended? = suspended_at.present? || organization.suspended?
```

This is the whole reason `organizations.owner_id` is a real column (Ticket A) — the chain is two `belongs_to` hops, preloadable with `includes(organization: :owner)`, not a join through membership rows.

Deriving rather than copying is what makes **unsuspend automatically correct**, which is the part that's easy to get wrong. Lifting an org's suspension instantly restores exactly the events that went down with it, while any event that was *also* suspended directly on its own merits stays suspended, because its own `suspended_at` is still set. No provenance column, no reconciliation job, and no possibility of org state and event state drifting apart.

### Two behaviours to keep straight

| | Direct event suspension | Cascade (org or owner suspended) |
|---|---|---|
| Sets `events.suspended_at` | Yes | No — derived |
| Unpublishes the event | Yes | No |
| Reversing it restores the event | No — organizer republishes | **Yes, automatically** |

The asymmetry is deliberate. Directly suspending an event is a judgment about *that event*, so it unpublishes and the organizer decides whether to bring it back. Cascade suspension is a judgment about the *organization*, so lifting it should undo it wholesale — an organizer cleared on appeal shouldn't have to republish fifty events, and for paid plans republishing would route back through the payment flow.

### Existing behaviour that must change

`User#suspend!` currently does `events.published.update_all(is_published: false)`. **Remove that.** With derivation, unpublishing is redundant for hiding the events, and actively wrong now: it would leave events unpublished after an unsuspend, contradicting the automatic-restore behaviour above. Its spec and doc comment both need updating — the comment explicitly documents the old republishing rule.

### Query surface

Every public-facing query needs to exclude cascade-suspended events. Add a scope and apply it to the public events listing, search, sitemap, and the organizer page's event list:

```ruby
scope :from_active_organizations, -> {
  joins(organization: :owner)
    .where(organizations: { suspended_at: nil }, users: { suspended_at: nil })
}
```

Audit every existing `Event.published` call site — missing one means a suspended organizer's event stays publicly visible, which is the exact failure this ticket exists to prevent.

### Admin surface

`POST /admin/organizations/:id/suspend` (reason required) and `/unsuspend`, mirroring the event endpoints exactly: `AdminAction` audit entries, and an email to the org owner stating the reason, including the org name, slug, and a link so they can appeal.

### Acceptance criteria

- Suspending an org hides all its events publicly and locks its team out of mutating them.
- Suspending a user cascades to orgs they own, and **not** to orgs they merely administer.
- Unsuspending an org restores its events automatically.
- An event suspended directly **stays suspended** after its org is unsuspended.
- `User#suspend!` no longer unpublishes events; its spec and comment are updated.
- Read-only access survives a cascade, exactly as it does for direct event suspension.
- The UI distinguishes *why* something is unavailable: "this event was suspended" vs "this organizer has been suspended".
- Every `Event.published` call site is audited and scoped.
- Suspended orgs 404 on the public organizer page.
- Specs cover the full matrix: direct-only, cascade-only, both at once, and each unsuspend path.

---

## Sequencing

A → B → C are strictly ordered: the model has to exist before credentials move onto it, and both before events point at it. D and E follow C. F depends on D and on J (the public page must already hide suspended orgs). G and H are frontend and can run in parallel once their APIs land. I and J are independent of the frontend work and can slot in any time after C.

```
A ──→ B ──→ C ──→ D ──→ F ──→ H
                   ├──→ E ──→ G
                   ├──→ I
                   └──→ J ──→ F
```

**Ship J before F and H reach production.** Until the cascade exists, the public organizer page is a surface that can display an organization Rally has already decided to suspend.

---

## Open questions

1. **Slug squatting.** Nothing stops someone registering `nike` or a rival's name as their slug. Probably fine at current scale; revisit if it happens — a reserved-word list is the cheap mitigation.
2. **Org-level notification preferences.** Notification settings live on `Profile` (personal). If a club wants event emails going to a shared inbox rather than the owner's, that's a separate change; `contact_email` in Ticket A is public-facing display only, not a delivery address.
3. **Transferring an event between organizations.** Not supported. Someone who creates an event under the wrong org has to delete and recreate it. Worth a follow-up if it comes up, but it interacts with payments (an event with paid registrations shouldn't change whose merchant account it settles to mid-flight).
