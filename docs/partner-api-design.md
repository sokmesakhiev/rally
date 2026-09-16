# Rally Partner API — design

**Status:** accepted · **Date:** 2026-09-16 · **Scope:** v1

Review closed §8's five questions; each is recorded inline at the decision it
affects, and §8 now holds the answers rather than the questions.

Rally's existing `/api/v1` is a private contract between the Rails app and its
own SPA: hand-built JSON that changes whenever the dashboard needs it to, JWTs
that live 30 days, endpoints shaped around screens. None of that should be
handed to a timing company. This document describes a second, public surface
— `/api/partner/v1` — with its own authentication, its own stability promise,
and its own authorization model, built on the same domain.

The five things it must let an integrator do, in the words of the request:
create an event, update results, get all participants, review and download
certificates, read payment information. Sections 3 and 4 cover those and the
handful of additions (webhooks, idempotency, bib numbers, a `/me`) without
which the five would be unpleasant to use.

---

## 1. Decisions

Each of these is written so it can be disagreed with. Where a choice is
reversible cheaply it says so; where it isn't, the reasoning is longer.

### D1 — The tenant is the Organization, not the User

An API credential belongs to an `Organization`, and every event it can touch
is one where `events.organization_id` matches.

Rally already has this concept (`organizations`, `organization_memberships`
with `member`/`admin` roles, an `owner_id`, the org's own PayWay credentials).
Integrators are businesses that contract with an organizing *company* —
"Phnom Penh Half Marathon Co." — not with whichever staff member happened to
set up the integration. If credentials hung off a user, that user leaving
would silently break the timing company's feed the night before a race, and
nobody in the org would be able to see or revoke a credential someone else
created.

Consequences: an API app is created and managed from the organization's
settings by an org `admin` or the owner; events created through the API get
`organization_id` set from the token, never from the request body; an app
cannot reach an event the org doesn't present, even if a member of that org
personally created it under a different org.

*Rejected:* per-user API keys mirroring the JWT. Simpler to build, wrong
ownership model, and it would make "who can see this org's data" depend on
the union of every member's personal keys.

### D2 — Doorkeeper, client credentials first, authorization code deferred

**Use Doorkeeper (5.9.x, current), and ship only the `client_credentials`
grant in v1.**

The challenge the request asked for, taken seriously: for the integrators
actually in scope — an organization's own tooling, timing partners acting for
one org — OAuth2's defining feature (a resource owner delegating to a third
party through a consent screen) is not needed. What *is* needed is: credentials
an org can create and revoke itself, short-lived bearer tokens so a leaked
token has a bounded blast radius, scopes so a timing partner gets
`results:write` and nothing else, and hashed secrets at rest. That is exactly
the `client_credentials` grant, and it is a subset of what Doorkeeper does.

So why Doorkeeper rather than a 150-line hand-rolled token endpoint?

- The token endpoint, secret hashing (`hash_application_secrets`,
  `hash_token_secrets`), expiry, revocation, scope validation and the
  standard error bodies are all things an integrator's OAuth client library
  already expects to find in a specific shape. Matching that shape by hand
  is where subtle bugs live (timing-safe comparison, `WWW-Authenticate`
  headers, the exact error codes), and none of it is Rally's problem to solve.
- **The upgrade path is free.** When a race-management SaaS wants "Connect
  Rally" inside their product for many orgs, that's the authorization-code +
  PKCE flow, and it uses the same `oauth_applications` / `oauth_access_tokens`
  tables, the same scopes, the same `doorkeeper_authorize!`. Turning it on is a
  config line plus the consent screen (below) — not a migration.
- It's ~14 years old, actively maintained, Rails 8 compatible, and the
  ActiveRecord ORM is the default. Nothing exotic.

What Doorkeeper does **not** give this codebase for free, and why the
authorization-code grant is deferred rather than included "since it's cheap":

- **There is no session and no server-rendered UI.** Doorkeeper's
  `/oauth/authorize` is a Rails-rendered consent page gated by
  `resource_owner_authenticator`, which in every tutorial is
  `current_user || redirect_to(login)`. Rally is API-only with a CloudFront
  SPA; there is no `current_user` from a cookie. Doorkeeper supports this
  (`api_only true`: skips CSRF, returns JSON from the authorize endpoint so a
  client can render consent itself), but it means building the consent
  screen in the SPA, POSTing the decision back with the existing JWT as the
  resource-owner proof, and handling `redirect_uri` allow-listing and PKCE
  verification end to end. That is a week of careful work with real security
  surface, and there is no customer for it yet.
- **Refresh tokens and their rotation** only matter for that grant. Client
  credentials just asks for a new token.

Configuration that is load-bearing for *this* app (all in
`config/initializers/doorkeeper.rb`):

```ruby
Doorkeeper.configure do
  orm :active_record
  api_only                                   # no CSRF, JSON everywhere
  base_controller "ActionController::API"
  grant_flows %w[client_credentials]         # authorization_code added later
  enable_application_owner confirmation: true # owner is the Organization (polymorphic)
  access_token_expires_in 1.hour
  hash_token_secrets                         # tokens unrecoverable from the DB
  hash_application_secrets                   # client secret shown once, at creation
  revoke_previous_client_credentials_token   # one live token per app; a leaked
                                             # old one dies on the next mint
  default_scopes  :"events:read"
  optional_scopes(*PartnerApi::SCOPES.keys)
  enforce_configured_scopes
  skip_authorization { false }
  # Doorkeeper's realm header leaks the gem name; set our own.
  realm "Rally Partner API"
end
```

Two consequences to know about:

- **Doorkeeper mounts `/oauth/token` at the root**, beside `/api/v1`. That's
  the one route outside a versioned namespace, and it's fine — it's the
  standard location clients look for. It needs its own rack-attack throttle
  (§6).
- **The JWT `authenticate_user!` and `doorkeeper_authorize!` must never see
  each other's tokens.** Both are `Authorization: Bearer …`. A JWT presented
  to the partner API is a decode failure in Doorkeeper (fine, 401); a
  Doorkeeper token presented to `/api/v1` would fail `JsonWebToken.decode`
  (fine, 401). Keeping the two under different namespaces with different base
  controllers is what makes "fine" stay true when someone later adds a
  fallback.

*Rejected:* **rodauth-oauth** — more complete (OIDC, DPoP, JWT access tokens)
but built on Rodauth's account model, which Rally doesn't use; adopting it
means adopting Rodauth. **Hand-rolled** — see above. **API keys only (no
token exchange)** — the honest alternative. It loses short-lived tokens
(every leaked key is live until noticed) and the free upgrade path. If the
team decides the token exchange is friction integrators will resent, this is
the one to reconsider, not rodauth.

### D3 — A separate namespace with its own base controller and serializers

`Api::Partner::V1::*` under `/api/partner/v1`, base class
`Api::Partner::V1::BaseController < ActionController::API`. It includes
`EventAuthorization` (the capability matrix is the right source of truth and
should not be duplicated) but **not** `ApplicationController`'s auth.

Serializers live in `app/serializers/partner/` as plain objects with `.call`
(the codebase's convention for anything shared — see `Support::Serializers`),
because the partner wire format is a *promise* and the internal `event_json`
hashes are not. Reusing the internal ones would mean every dashboard change
is a breaking API change.

Versioning: URL path (`/v1/`). Additive changes (new fields, new endpoints,
new webhook types) do not bump it. Removing or renaming a field, changing a
status code, changing pagination shape — those go in `/v2/` with `/v1/`
supported for a stated window. Integrators must ignore unknown fields; the
docs say so.

### D4 — Authorization: the app is a Manager of the org's events, never an Owner

A token resolves to `(application → organization)`. For any event, the app's
effective role is:

- `:manager` if `event.organization_id == org.id`
- nothing (404) otherwise

then narrowed by the token's scopes. This reuses `EventAuthorization`'s
`CAPABILITIES` exactly — a request needs *both* the capability for
`:manager` **and** the matching scope. Capabilities that the matrix reserves
for `:owner` are therefore unreachable through the API by construction:
`manage_plan` (spends the owner's money), `delete_event`, `unpublish_event`,
`manage_members`. That is intended. An integration should not be able to
delete an event or change who runs it; a human does that in the dashboard.

Suspended events and suspended organizations behave as they do for humans:
`SUSPENDED_ALLOWED_CAPABILITIES` still apply, everything else is 403. One
difference: the internal concern renders a bare `"Forbidden"` for a suspended
event, which is fine when the dashboard already shows the suspension banner.
An integrator has no banner, so the partner API adds `code: "event_suspended"`
/ `"organization_suspended"` to that 403 — a new code, not an existing one.

*Why not "act as the org owner user":* it would grant `manage_plan` and
`delete_event` to a bearer token, and it would attribute every API write in
`event_activities` to a person who didn't do it.

### D5 — Scopes

| Scope                | Grants                                                                 |
|----------------------|------------------------------------------------------------------------|
| `events:read`        | list/read events, event types, registration status. *(default)*       |
| `events:write`       | create/update events and event types; close/reopen registration        |
| `participants:read`  | list participants **including name and email**                         |
| `participants:write` | set/clear bib numbers; check in                                        |
| `results:write`      | bulk upsert results (implies `participants:read` for matching)         |
| `certificates:read`  | list certificates, get download URLs                                   |
| `payments:read`      | payment and refund records                                             |
| `webhooks:manage`    | create/rotate/delete webhook endpoints                                 |

Three deliberate choices. `participants:read` includes email because the
integrators in scope (timing, bib assignment, certificate delivery) cannot
function without it, and the org already has it; it is called out in the
scope description so an org granting it to a marketing tool knows what it's
granting.

**Phone is never exposed, by any scope** (review decision). The proposed
`participants:read_phone` is dropped rather than shipped-but-off: an unused
scope is a thing someone enables later without re-asking the question. If a
race-kit delivery partner ever needs it, that's a new scope with a fresh
argument, and the absence of the column from `Partner::ParticipantSerializer`
is what forces that conversation to happen.

**There is no `refunds:write` in v1** — that moves money, the existing
dashboard flow has a human confirming an amount, and no integrator has asked.
Read access to refunds is in `payments:read`.

Scopes are fixed per application at creation and editable by an org admin;
the token endpoint may request a subset (`scope=` param), never a superset.

### D6 — Idempotency on every write

`POST`/`PUT`/`PATCH` accept an `Idempotency-Key` header (UUID, ≤ 255 chars).
Semantics follow Stripe's, which every integrator already knows:

- Same key + same request fingerprint (method, path, body hash) within 24h →
  the stored response is replayed, with `Idempotent-Replayed: true`.
- Same key + different fingerprint → `422 idempotency_key_reused`.
- Storage is a table (`partner_idempotency_keys`: application_id, key,
  fingerprint, status, body, created_at; unique on `(application_id, key)`),
  not Solid Cache — a cache can evict, and a replayed create that becomes a
  duplicate event is worse than the extra table. Swept after 24h by the same
  hourly recurring pattern as `Certificates::SweepPreviews`.

The key is scoped per application, so two apps can't collide, and a retried
`PUT /events/:id/results` after a network timeout cannot double-apply.

### D7 — Webhooks, signed and delivered from the worker

The single most valuable addition. Without it a timing partner polls
`/participants` every minute, which on a web task with **three Puma threads**
is the load that matters most.

- **Endpoints** are per-organization (`partner_webhook_endpoints`: org,
  application, url, secret_digest, subscribed event types, status,
  consecutive_failures, disabled_at). URL must be `https`, not a private or
  link-local address (resolve at save time; the SSRF concern is the same one
  that shaped `certificate_preview`'s `signed_id` decision).
- **Signature**: `Rally-Signature: t=<unix>,v1=<hex>` where
  `v1 = HMAC-SHA256(secret, "#{t}.#{raw_body}")`. Receivers reject `t` older
  than 5 minutes. The secret is shown once on creation; `POST …/rotate`
  returns a new one and honours the old for 24h (both signatures sent as
  `v1=…,v1=…` during the overlap) so rotation needs no downtime.
- **Delivery** is a Solid Queue job on the worker, enqueued inside
  `ActiveRecord.after_all_transactions_commit` — the exact discipline
  `Conversations::Broadcast` already follows, and for the same reason: never
  announce a row that a rollback then removes. Retries: 1m, 5m, 30m, 2h, 12h.
  After five failures the delivery is marked `failed`; after 72h of
  consecutive failures on an endpoint it is disabled and the org's admins are
  notified in-app (via the existing notification row pattern).
- **Payloads are a hint, not the truth.** Each carries `id`, `type`,
  `occurred_at`, and a `data` object with the affected resource in the same
  shape the REST API returns. Docs tell integrators to treat it as a signal to
  fetch, because deploys and retries mean delivery is at-least-once and
  possibly out of order — the same "REST is the source of truth" principle the
  codebase applies to ActionCable.
- **Deliveries table** (`partner_webhook_deliveries`: endpoint, event type,
  payload, attempt, status, response_code, last_error, next_attempt_at) is
  visible to the org in the dashboard and swept after 30 days.

Event types in v1:

| Type                          | Fires when                                                |
|-------------------------------|-----------------------------------------------------------|
| `registration.created`        | a registration row is created (paid or unpaid)            |
| `registration.paid`           | `payment_status` becomes `paid` (both the poll and webhook paths — one notifier, like `RegistrationNotifier`) |
| `registration.cancelled`      | status → cancelled, including `ReleaseAbandoned` sweeps   |
| `registration.checked_in`     | check-in, and `registration.check_in_undone` on undo      |
| `registration.bib_assigned`   | bib set or changed                                        |
| `event.updated`               | any field the partner API exposes changes                 |
| `event.registration_closed`   | close, and `event.registration_reopened`                  |
| `results.updated`             | **once per bulk upsert**, with counts — not per row       |
| `certificate.issued`          | `Certificate` row written with a `file_url`              |
| `payment.refunded`            | a refund reaches `succeeded`                              |

### D8 — Cursor pagination on list endpoints

`?limit=` (default 50, max 200) and `?cursor=` (opaque, base64 of
`(updated_at, id)`), with `next_cursor` in the response. Not the internal
`page`/`per_page`.

The internal convention exists for a human paging through a table, where
drift between pages is invisible. An integrator syncing 8,000 registrations
while people are still registering will *lose rows* under offset pagination
whenever an insert shifts the window. Keyset over `(updated_at, id)` doesn't,
and combined with `?updated_since=` it gives incremental sync for free. The
codebase already has the `(created_at, id)` pair comparison in
`Message.after_id` for the same reason.

### D9 — Errors are one shape

```json
{ "error": { "code": "registration_closed", "message": "Registration is closed for this event.", "details": [] } }
```

`code` is stable and documented; `message` is not. `details` carries
per-field or per-row problems. Existing machine-readable codes are reused
verbatim (`full`, `registration_closed`, `recaptcha_failed`'s shape) so the
two surfaces never disagree about what a state is called; codes the partner
API introduces (`event_suspended`, `plan_payment_required`, `bib_taken`,
`not_eligible`, `idempotency_key_reused`) should be added to the internal
controllers too where the same condition exists, rather than living only here. Every response carries
`X-Request-Id`.

### D10 — Bib numbers need to exist

`results` has `registration_id`, `finish_time_seconds`, `notes`. There is **no
bib number anywhere in the schema**, and `Results::ImportCsv` matches rows by
*email*. That works for an organizer pasting a spreadsheet; it does not work
for a timing system, whose entire data model is keyed on bib. Handing a timing
company an API where they have to look up every finisher's email is an API
nobody will use.

Add `registrations.bib_number` (string, nullable, unique per event where
not null). The partner API accepts any of `registration_id`, `bib_number`,
`email` as the match key on results upsert; `participants:write` can assign
bibs in bulk; the dashboard shows and edits it; the CSV import gains a `bib`
column. This is a small change to the core model that the API requires and
the product should have had anyway.

### D11 — Certificates are downloaded via short-lived signed URLs, and the generator isn't running

The certificate endpoint returns metadata plus a URL that expires (Active
Storage's redirect URL, 15 minutes), never proxies bytes through Puma, and
never returns the stored `file_url` directly — rows written before the
`Storage::BlobUrl` fix still hold the wrong host, and the API is the first
consumer that would notice.

**Found while checking this:** `GenerateCertificatesJob`'s header comment says
it "runs on a schedule (see `config/recurring.yml`)". It is not in
`recurring.yml`, and nothing else calls it — no `perform_later` anywhere
outside the job file. In production, **certificates are not being generated
for anyone.** The certificate endpoints are worthless until that is fixed, so
it leads Phase 0.

**And it cannot simply be switched on.** `eligible_registrations` filters on
`status`, `payment_status`, template presence and end date — but not on
`registrations.deleted_at`, `events.deleted_at` or `events.suspended_at`. Every
other read of registrations in this codebase goes through `.kept`. So the
first time this job runs it would issue certificates to people who withdrew
and were discarded, and to registrations on events an admin has taken down —
each one a rendered PDF in S3 and a row that the organizer never asked for.
The bug is invisible today only because the job is dead code. Fixing the scope
is part of turning it on, not a follow-up.

**Backfill policy** (review decision): no date cutoff — every event that has
*finished* is eligible, however long ago. The population is therefore bounded
by history rather than by a window, which on first run could be thousands of
renders at ~180 MB RSS and 0.25–1.2 s each. So the job takes a per-run
fan-out cap (`MAX_PER_RUN`, 200): the hourly schedule drains any backlog over
a few hours instead of enqueueing it all at once, and in steady state the cap
is never reached. That satisfies "apply to finished events" without a one-off
migration script and without a thundering herd on the worker.

### D12 — Publishing through the API: free tier only

`POST /events/:id/publish` succeeds only when the event fits `Event::PLANS["free"]`
(capacity ≤ 20, no plan payment). Anything larger returns
`409 plan_payment_required` with the dashboard URL. Publishing a paid tier
charges the org owner's card, which is the exact reason `manage_plan` is
owner-only in the matrix, and a bearer token must not be able to do it. Draft
creation is unrestricted; a partner can build the whole event and hand it to
a human for the one click that costs money.

### D13 — Attribution in the activity log

`event_activities.actor_id` is a non-null FK to `users`. API writes have no
user. Add a nullable `application_id` (FK to `oauth_applications`) and relax
`actor_id` to nullable with a CHECK that exactly one of the two is set; the
dashboard renders "via *Timing Co. integration*". Doing this properly costs a
migration; doing it badly (attributing to the org owner) makes the audit log
lie, which is the one thing an audit log must not do.

---

## 2. Authentication flow

```
Org admin, in dashboard → Settings → Integrations → "New application"
   name, scopes, (optional) webhook URL
   ← client_id, client_secret (shown once), scopes

Integrator:
   POST /oauth/token
        grant_type=client_credentials
        client_id=…&client_secret=…
        scope=results:write participants:read        (optional subset)
   ← { access_token, token_type: "Bearer", expires_in: 3600, scope }

   GET /api/partner/v1/me
        Authorization: Bearer <access_token>
   ← { organization: {id, name, slug}, application: {id, name}, scopes: [...] }
```

Token lifetime is one hour. `revoke_previous_client_credentials_token` means
minting a new one kills the previous, so an integrator running two processes
should share a token cache — documented, and standard. Revoking the
application from the dashboard revokes all its tokens immediately
(Doorkeeper does the cascade).

---

## 3. Endpoints

All under `/api/partner/v1`. Money is always `*_cents` + `currency`. Times are
ISO 8601 UTC. IDs are UUIDs.

### Meta

| Method | Path   | Scope | Notes |
|--------|--------|-------|-------|
| GET | `/me` | any | org, app, granted scopes, rate-limit ceiling. First call every integrator makes; makes misconfiguration obvious. |

### Events

| Method | Path | Scope | Notes |
|--------|------|-------|-------|
| GET | `/events` | `events:read` | org's events; `?status=draft\|published\|ended`, `?updated_since=` |
| POST | `/events` | `events:write` | body mirrors `EventRequestSchema` minus `organization_id` (taken from token) and `survey_id`; `event_types[]` inline; **created as draft** |
| GET | `/events/:id` | `events:read` | includes `event_types`, capacity, registration counts (from `Registrations::Summary`), `registration_closed`, `plan` |
| PATCH | `/events/:id` | `events:write` | `EventUpdateRequestSchema` fields; `registration_closed_at` excluded, as internally |
| POST | `/events/:id/publish` | `events:write` | free tier only — see D12 |
| POST | `/events/:id/close_registration` | `events:write` | idempotent, as internally |
| POST | `/events/:id/reopen_registration` | `events:write` | |
| GET / POST / PATCH / DELETE | `/events/:id/event_types[/:type_id]` | `events:read` / `events:write` | delete refused with `409 has_registrations` |

Banner and logo: `POST /events/:id/banner` and `/logo` accept multipart,
reuse `UploadsController`'s validation, and enforce the 1600×400
recommendation as guidance in the response, not a rejection.

### Participants

| Method | Path | Scope | Notes |
|--------|------|-------|-------|
| GET | `/events/:id/participants` | `participants:read` | cursor-paginated; `?q=` (server-side search, as internally), `?status=`, `?payment_status=`, `?checked_in=`, `?updated_since=`, `?event_type_id=` |
| GET | `/events/:id/participants/summary` | `events:read` | `Registrations::Summary` as-is: totals, paid/unpaid, checked in, revenue, per type |
| GET | `/participants/:registration_id` | `participants:read` | |
| PUT | `/events/:id/participants/bibs` | `participants:write` | bulk `[{registration_id\|email, bib_number}]`, ≤ 500; per-row outcome; `409 bib_taken` per row |
| POST | `/participants/:id/check_in` | `participants:write` | returns `already_checked_in`, as internally |
| DELETE | `/participants/:id/check_in` | `participants:write` | undo |

Participant shape: `id`, `status`, `payment_status`, `bib_number`,
`checked_in_at`, `created_at`, `updated_at`, `event_types[]`,
`user: {id, display_name, email}`, `amount_owed_cents`, `amount_paid_cents`,
`currency`. **Not** exposed: `phone` (D5), `refund_policy_tiers`, anything
else from `profiles`, PayWay fields of any kind.

Removing a participant is deliberately **not** in v1 — it's destructive, it
has refund implications, and the dashboard has a confirmation dialog for a
reason.

### Results

| Method | Path | Scope | Notes |
|--------|------|-------|-------|
| GET | `/events/:id/results` | `events:read` | `Results::BuildLeaderboard` output (public data anyway) |
| PUT | `/events/:id/results` | `results:write` | bulk upsert, ≤ 500 rows: `[{bib_number\|registration_id\|email, finish_time_seconds, notes?}]`; response lists `applied`, `unchanged`, `errors[{index, key, code}]`; fires one `results.updated` |
| DELETE | `/events/:id/results/:registration_id` | `results:write` | remove a result (DNF corrections) |

Match precedence when several keys are supplied: `registration_id`, then
`bib_number`, then `email`; conflict between supplied keys is a per-row
error, not a silent pick. Refuses rows for registrations that are not
`confirmed`+`paid` with `code: "not_eligible"`, matching
`GenerateCertificatesJob`'s eligibility so a result never exists for someone
who can't get a certificate.

### Certificates

| Method | Path | Scope | Notes |
|--------|------|-------|-------|
| GET | `/events/:id/certificates` | `certificates:read` | cursor-paginated; `status: issued\|pending`; pending = eligible registration with no `Certificate` row yet |
| GET | `/participants/:id/certificate` | `certificates:read` | `{ status, issued_at, download_url, expires_at }` — URL is a 15-minute signed redirect |
| POST | `/events/:id/certificates/regenerate` | `certificates:read` + `events:write` | after a template change; enqueues `RenderCertificateJob` per eligible registration, `202` with a count; throttled to once per 10 minutes per event because each render is ~180 MB RSS on the worker |

Depends on D11's fix.

### Payments

| Method | Path | Scope | Notes |
|--------|------|-------|-------|
| GET | `/events/:id/payments` | `payments:read` | cursor-paginated; `?status=`, `?paid_since=` — the reconciliation feed |
| GET | `/participants/:id/payments` | `payments:read` | |
| GET | `/payments/:id` | `payments:read` | includes `refunds[]` |

Payment shape: `id`, `registration_id`, `provider`, `status`, `amount_cents`,
`currency`, `tran_id` (the PayWay reference an accountant will search for),
`paid_at`, `expires_at`, `refunded_amount_cents`, `refunds[{id, amount_cents,
status, reason, refund_method, refunded_at}]`. **Never**: `qr_string`,
`abapay_deeplink`, `raw_response`, or anything about the org's PayWay
credentials. `EventPlanPayment` (what the org paid Rally) is exposed
read-only as `event.plan_payment` on the event resource, since accountants
reconcile that too.

### Public (no authentication)

Approved at review. Under `/api/partner/v1/public/…`, no token, for embedding a
start list or leaderboard on a club's own website — the case where requiring a
client secret in a `<script>` tag would be worse than requiring nothing.

| Method | Path | Notes |
|--------|------|-------|
| GET | `/public/events/:id` | published, non-suspended, non-deleted events only; the same shape as the authenticated event resource minus revenue, plan and plan payment |
| GET | `/public/events/:id/results` | leaderboard — already public internally |
| GET | `/public/events/:id/starters` | **display name, bib and event type only** |
| GET | `/public/organizations/:slug/events` | the org's published events |

The whole design risk sits in `starters`, and it is resolved by what the
endpoint *cannot* return rather than by rate limits:

- **No email, ever, under any parameter.** A scraper's prize here is a list of
  runners' addresses, and the way to not lose them is to not have them in the
  serializer. `Partner::PublicStarterSerializer` is a separate object from the
  authenticated one for exactly this reason — one shared serializer with a
  conditional is one boolean away from a leak.
- **No payment state, no `checked_in_at`, no registration id.** "Who has paid"
  and "who has turned up" are the organizer's business. The id is withheld so
  a public response can't be used as an input to any authenticated endpoint.
- **Opt-in per event**, defaulting to off: `events.public_starters` boolean.
  A start list is normal for a public race and unwelcome for a corporate 5K,
  and that judgement is the organizer's, made once in the dashboard. A
  published event is not consent to publish its entrant list.
- **Unpublished, suspended and soft-deleted events 404**, as they do for
  anonymous users elsewhere.
- Throttled by IP (`partner_public/ip`, 120 per 5 min), cached 60s at the edge
  via `Cache-Control: public, max-age=60` — these are the only partner
  responses that are CDN-cacheable, and given they run on a three-thread web
  task, that header is doing more work than the throttle is.

`?updated_since=` is deliberately absent from the public endpoints: it turns a
snapshot into a change feed, which is a sync tool, which is what the
authenticated API is for.

### Webhooks

| Method | Path | Scope | Notes |
|--------|------|-------|-------|
| GET / POST | `/webhook_endpoints` | `webhooks:manage` | create returns `secret` once |
| PATCH / DELETE | `/webhook_endpoints/:id` | `webhooks:manage` | change URL / event types; disable |
| POST | `/webhook_endpoints/:id/rotate_secret` | `webhooks:manage` | 24h overlap |
| POST | `/webhook_endpoints/:id/test` | `webhooks:manage` | sends a `ping` event synchronously, returns the response code |
| GET | `/webhook_endpoints/:id/deliveries` | `webhooks:manage` | last 30 days |
| POST | `/webhook_deliveries/:id/redeliver` | `webhooks:manage` | |

---

## 4. Data model changes

| Change | Why |
|--------|-----|
| Doorkeeper tables (`oauth_applications` with polymorphic `owner`, `oauth_access_tokens`, `oauth_access_grants`) | generator output; grants unused until authorization-code lands |
| `registrations.bib_number` string, unique `(event_id, bib_number) WHERE bib_number IS NOT NULL` | D10 |
| `partner_idempotency_keys` | D6 |
| `partner_webhook_endpoints`, `partner_webhook_deliveries` | D7 |
| `events.public_starters` boolean, default false | public start list is opt-in (§3, Public) |
| `event_activities.application_id` nullable FK; `actor_id` nullable; CHECK one-of | D13 — **Phase 1, not Phase 0**: the FK target is `oauth_applications`, which Doorkeeper creates |
| `recurring.yml`: `generate_certificates` hourly; `sweep_partner_idempotency_keys`, `sweep_partner_webhook_deliveries` | D11, D6, D7 |

Nothing changes on `payments`, `results`, `certificates`, `events`.

---

## 5. Frontend (dashboard) work

Organization settings gains an **Integrations** panel: list applications
(name, scopes, created by, last used), create (shows secret once with a copy
button and the sentence "you won't see this again"), edit scopes, revoke;
webhook endpoints with delivery log and a "send test" button. Org `admin` or
owner only — `OrganizationMembership#admin?` is the gate. `last_used_at` on
the application (Doorkeeper doesn't track it; one `touch` in the base
controller, throttled to once per minute per token) is what lets an admin
spot a dead integration to revoke.

The Participants tab shows and edits `bib_number` and gains it as a search
field.

---

## 6. Security and operations

- **rack-attack**: `oauth_token/client` 30/min per `client_id`,
  `oauth_token/ip` 60/min; `partner/token` 600 per 5 min per access token
  (the same window as the existing `req/ip`); bulk endpoints (`PUT results`,
  `PUT bibs`) 30 per 5 min per token. Responses carry
  `RateLimit-Limit/Remaining/Reset`.
- **Secrets**: hashed at rest (D2); shown once; never logged. The existing
  `filter_parameters` (`:secret`, `:token`, `:_key`) already match
  `client_secret`, `access_token` and webhook `secret` by substring, so no
  change is needed there — worth a spec asserting it, since it's easy to
  assume rather than check.
- **Webhook URLs**: HTTPS only; resolved and checked against private ranges
  at save time *and* at delivery time (DNS can change between the two). 5s
  connect / 10s read timeout. No redirects followed.
- **Token in URL** is rejected (`?access_token=` disabled —
  `access_token_methods :from_bearer_authorization` only), for the same
  reason the cable ticket exists: query strings land in ALB logs.
- **Logging**: every partner request logs `application_id`,
  `organization_id`, scopes used, and `X-Request-Id`; never the token.
- **Suspension**: suspending an organization (admin action, already exists)
  must revoke its tokens — add that to `Organization#suspend!`.
- **Brakeman/bundler-audit** already in `bin/`; Doorkeeper has had CVEs
  (2023, token introspection) — pin `~> 5.9` and let Dependabot move it.
- **Load**: every list endpoint is cursor-paginated and capped at 200; every
  bulk write capped at 500 rows; certificate regeneration throttled.
  Webhook delivery is on the worker, not the web task. This API adds no
  held-open connections and no unbounded queries to the three threads.

---

## 7. Rollout

| Phase | Ships | Depends on |
|-------|-------|------------|
| **0 — prerequisites** | `GenerateCertificatesJob` eligibility fix + `MAX_PER_RUN` + `recurring.yml`; `bib_number` migration, model, search, CSV import column, dashboard field | — |
| **1 — auth + events + participants** | Doorkeeper install and config; `event_activities.application_id` (needs Doorkeeper's tables); `Api::Partner::V1::BaseController`; `/me`; Events CRUD (draft), event types, close/reopen, free-tier publish; Participants list/summary/show; bibs bulk; check-in; Integrations panel in org settings; idempotency; rack-attack; request specs | 0 |
| **2 — results, certificates, payments** | results bulk upsert + delete; certificates list/show/regenerate; payments read; `last_used_at` | 1 |
| **3 — public + webhooks** | `events.public_starters` + dashboard toggle; the four public endpoints with their own serializers and edge caching; webhook endpoints, signing, delivery job, retries, delivery log, `test`/`redeliver` | 1 |
| **4 — later, when there's a customer** | authorization-code + PKCE with SPA consent screen; participant-facing scopes; `refunds:write` with a per-app enablement flag; OpenAPI document published from the request schemas | 3 |

Each phase is independently mergeable and useful. Phase 1 alone lets a timing
company pull the start list; Phase 2 lets them push finishers; Phase 3 stops
them polling.

---

## 8. Review decisions

1. **Token exchange, not static keys.** Doorkeeper with `client_credentials`
   as designed in D2. Integrators cache a token for an hour; the payoff is
   that a leaked credential expires on its own and the authorization-code
   upgrade needs no migration.
2. **Phone is not exposed by any scope.** The proposed
   `participants:read_phone` is dropped entirely rather than shipped disabled
   — see D5.
3. **Public unauthenticated reads are in**, as a distinct section of §3 with
   their own serializers, an opt-in `events.public_starters` flag, and no
   email or payment state in any response. Phase 3.
4. **Certificate backfill has no date cutoff** — every finished event
   qualifies — with a per-run fan-out cap so the historical backlog drains
   over hours rather than at once. See D11.
5. **`/api/partner/v1`** confirmed.

Two things settled implicitly by the above, recorded so they aren't
re-litigated: the public endpoints do **not** share serializers with the
authenticated ones (a conditional field is one boolean away from a leak), and
`event_activities.application_id` moves from Phase 0 to Phase 1 because its FK
target is a table Doorkeeper creates.
