# Support chat — ticket series

Logged-in participants can open a direct chat with Rally staff; staff answer from
the existing admin console. Real-time delivery over ActionCable.

**Decisions already made** (recorded here so they aren't relitigated mid-build):

| Question | Decision |
| --- | --- |
| Build vs. hosted widget (Crisp/Intercom/Tawk) | **Build in-house.** Keeps participant data in our own Postgres and lets the agent view read Rally context — this user's registrations, payments, refunds — with no extra integration. |
| Who talks to whom | **Participant ↔ Rally staff only.** Organizer ↔ participant chat is explicitly out of scope (see Non-goals). |
| Transport | **ActionCable / WebSockets**, not polling. |

**Total size: ~13–18 dev-days** (≈3–4 calendar weeks for one developer including
review cycles). Polling would have been ~10–13 days; the WebSocket choice costs
roughly 3–4 extra days up front plus a permanent piece of production surface to
operate. Ticket 0 is the gate that decides whether that bet holds.

| Ticket | Scope | Size |
| --- | --- | --- |
| 0 | Enable ActionCable in production (spike, go/no-go) | 1.5–2.5 d |
| A | Data model: `Conversation`, `Message` | 0.5–1 d |
| B | Participant REST API | 1 d |
| C | Staff REST API + audit logging | 1–1.5 d |
| D | `ChatChannel` and the broadcast layer | 1 d |
| E | Participant UI (launcher + panel) | 2.5–3.5 d |
| F | Staff console tab | 2.5–3.5 d |
| G | Notifications + offline email fallback | 1 d |
| H | Rate limiting, retention, abuse | 1–1.5 d |
| — | Specs, docs, `CLAUDE.md` | folded into each |

Build them in order. 0 → A → B/D → C → E/F → G → H. Nothing after 0 is worth
starting until 0 has run on staging with the real task count.

---

## Ticket 0 — Enable ActionCable in production

**This is a spike with a go/no-go decision at the end, not a feature ticket.** It
ships no chat. It answers one question: can this deployment hold open WebSocket
connections without destabilising the API?

### Problem

ActionCable is not loaded at all. `backend/config/application.rb` requires seven
railties individually and `action_cable/railtie` is not among them. The
`solid_cable` gem is not in the `Gemfile` even though `backend/config/cable.yml`
already names `adapter: solid_cable` for production — that file is `rails new`
scaffolding that has never run. The `cable` database *is* created on every boot
(`bin/docker-entrypoint` runs `db:prepare`, which creates every database declared
under `production:` in `database.yml`), so the storage is there and empty.

### Why it matters

Production is 3 Puma threads per task across 2 ECS tasks. Earlier in this
codebase's history that math was used to rule out SSE for the notification badge,
and that reasoning was correct **for SSE** — a held-open Rack response occupies a
Puma thread for its entire life, so six concurrent listeners would have consumed
the entire request capacity.

ActionCable is not the same shape and the earlier framing was imprecise about it.
ActionCable calls `env["rack.hijack"]`, takes the socket off Puma entirely, and
hands it to its own nio4r event loop. The Puma thread is returned to the pool as
soon as the upgrade completes. **Open connections do not each pin a request
thread.** The real limits are elsewhere, and this ticket is about finding them:

1. **The Active Record pool is 5, and that is the binding constraint.** ActionCable
   runs callbacks (`connect`, `subscribed`, `receive`, broadcasts) on a worker pool
   — `config.action_cable.worker_pool_size`, default **4** — and each of those
   threads checks out a database connection.

   `backend/config/database.yml` sets `max_connections: <%= ENV.fetch("RAILS_MAX_THREADS") { 5 } %>`.
   That key is correct: in Rails 8.1 `max_connections` is the canonical pool
   setting and `pool` is its deprecated alias (`HashConfig#max_connections`,
   with `alias :pool :max_connections` and a deprecation on `pool`). Setting
   `pool:` here instead would be a step backwards, and `validate_configuration!`
   raises outright if both are set to different values — so leave the key alone.

   The problem is the **value**. `RAILS_MAX_THREADS` is not set anywhere in
   `infrastructure/ecs.tf`, so the fallback applies and every process runs a
   primary pool of exactly **5**, already shared by Puma's 3 request threads and
   whatever Solid Queue executes in-process (`SOLID_QUEUE_IN_PUMA=true`). Adding
   ActionCable's 4 worker threads to a pool of 5 will produce
   `ActiveRecord::ConnectionTimeoutError` after the default 5-second checkout
   wait — intermittently, only under concurrency, which is the worst way to find
   out.

   Set `RAILS_MAX_THREADS` explicitly in `ecs.tf` so Puma threads and the pool
   are sized by decision rather than by a fallback, and size the pool as
   `puma_threads + cable_worker_pool + headroom`. There is ample room at the
   database: `db.t3.micro` (1 GiB) gives Postgres roughly 112 connections, and
   2 tasks × a pool of ~10 is nowhere near it.

   Confirm on a console before and after:

   ```ruby
   ActiveRecord::Base.connection_pool.size
   ```

2. **Solid Cable's polling interval.** `cable.yml` ships `polling_interval:
   0.1.seconds` — every process polls the cable database **ten times a second,
   forever**, whether or not anyone is chatting. At 2 tasks that is a constant 20
   queries/sec of pure overhead. Support chat does not need 100 ms delivery;
   **raise it to `0.5.seconds`** and note the reasoning in the file.

3. **`allowed_request_origins`.** Unset, ActionCable rejects cross-origin
   connections in production. The frontend is served from CloudFront on a
   different origin than the API, so **every connection will be refused** until
   this is configured. Easy to miss because development defaults to permissive.

4. **ALB behaviour.** ALB proxies WebSockets natively over HTTP/1.1, but its
   default idle timeout is 60 s. ActionCable pings every 3 s by default, which
   should hold the connection open — verify rather than assume, and confirm
   nothing in `infrastructure/` shortens the timeout (nothing sets it today).

5. **Every deploy severs every connection.** `aws ecs update-service
   --force-new-deployment` replaces tasks. This is not an edge case to handle
   later; it is the normal weekly behaviour of this system.

### Proposed scope

- Add `action_cable/railtie` to `config/application.rb`. Note that
  `config.api_only = true` is fine — ActionCable does not need Action View.
- `gem "solid_cable"`, production group, alongside `solid_queue`/`solid_cache`.
- Size `max_connections` in `database.yml` deliberately and comment the math; set
  `RAILS_MAX_THREADS` explicitly in `ecs.tf`.
- `polling_interval: 0.5.seconds` in `cable.yml`.
- `config.action_cable.allowed_request_origins` in
  `config/environments/production.rb`, driven by an env var so it tracks the
  CloudFront domain rather than being hardcoded.
- **Cable connection auth** (see below).
- A trivial `PingChannel` that echoes, plus a scratch page, purely to prove the
  path end to end on staging. Deleted in Ticket D.
- Load check on staging with the real task count: 200 idle connections, confirm
  memory per connection and that REST latency is unmoved.

### Cable connection auth

Auth is JWT (`lib/json_web_token.rb`, `Authorization: Bearer`). **The browser
WebSocket API cannot set request headers**, so the usual approach — putting the
token in the query string — is not available to us: it would write a valid
credential into ALB access logs, CloudWatch, and browser history. That is a real
leak, not a theoretical one.

Use a **short-lived, single-use ticket** instead:

```
POST /api/v1/cable/ticket        # authenticated with the normal Bearer JWT
  -> { ticket: "<32 random bytes, base64url>", expires_in: 30 }
```

Store `cable:ticket:<digest>` → `user_id` in Solid Cache with a 30-second TTL.
The client then opens `wss://<api>/cable?ticket=…`. `ApplicationCable::Connection#connect`
looks the ticket up, **deletes it immediately** (single use), and rejects the
connection if it is missing or expired. A leaked ticket is worthless within 30
seconds and cannot be replayed. The long-lived JWT never touches a URL.

The client must fetch a fresh ticket before each reconnect attempt — fold this
into the consumer factory in Ticket D so component code never thinks about it.

The alternative — smuggling the token through `Sec-WebSocket-Protocol` — works
and avoids the extra round trip, but it abuses a header meant for subprotocol
negotiation and is harder to reason about later. Ticket approach preferred.

### Go / no-go

If staging shows connection-pool exhaustion, memory growth per connection worse
than budgeted, or REST p95 regression, **stop and fall back to polling**. That
costs the 2 days spent here, not the three weeks after it. Record the numbers in
`docs/` either way.

### Open questions

- Is there an ALB access log we need to re-check for tickets in URLs after launch?

---

## Ticket A — Data model

### Proposed scope

Two tables, both UUID PKs to match the rest of the schema.

**`conversations`**

| Column | Notes |
| --- | --- |
| `user_id` | The participant. Not null. Staff are *not* participants in the row. |
| `status` | `open` / `pending` / `resolved`. |
| `subject` | Optional, nullable — first message's opening line if we want it. |
| `assigned_admin_id` | Nullable. Soft claim: "someone is on this", not exclusive. |
| `last_message_at` | Denormalised for inbox ordering. |
| `participant_last_read_at` | See below. |
| `staff_last_read_at` | See below. |

Indexes: `(status, last_message_at DESC)` for the inbox, `(user_id)`, and a
**partial unique index on `user_id WHERE status <> 'resolved'`** — one open thread
per participant. This mirrors the partial-index pattern already used on
`registrations (event_id, user_id) WHERE deleted_at IS NULL`; carry a matching
`conditions:` on the model validation the same way, or the two disagree.

**`messages`**

| Column | Notes |
| --- | --- |
| `conversation_id` | Not null. |
| `sender_id` | A `User` — participant or staff. |
| `sender_role` | `participant` / `staff` / `system`. **Denormalised on purpose.** |
| `body` | Not null, length-capped. |

Index `(conversation_id, created_at)`.

### Two design points worth not rediscovering later

**Read state is two timestamps on the conversation, not a join table.** There is
exactly one participant, and staff act as a *pool* rather than as individuals
subscribed to a thread. `participant_last_read_at` and `staff_last_read_at` answer
every question the UI asks ("does this thread have unread staff replies", "how
many open threads have unread participant messages") with no extra table and no
per-agent fan-out. Revisit only if staff ever need per-agent read receipts, which
is a different product.

**`sender_role` is snapshotted, not derived from `users.admin`.** Revoking
someone's admin flag must not silently rewrite months of history so their past
replies render as if a participant sent them. Same reasoning as
`Registration#snapshot_refund_policy` — when a fact is part of the record of what
happened, store it on the record.

---

## Ticket B — Participant REST API

### Proposed scope

Under `Api::V1`, authenticated, following the existing hand-built-JSON convention
(no serializers — see `event_json`, `payment_json`):

```
GET   /api/v1/support/conversation              # the caller's open thread, or null
POST  /api/v1/support/conversation              # open one (idempotent — returns the existing open thread)
GET   /api/v1/support/messages?after=<id>       # history; `after` powers reconnect catch-up
POST  /api/v1/support/messages                  # send
POST  /api/v1/support/read                      # stamp participant_last_read_at
```

`GET /messages?after=<id>` is the important one and is **not** optional. The
socket is a delivery optimisation; this endpoint is the source of truth. Every
reconnect — and there is one on every deploy — refetches from the last id the
client actually holds. A chat that trusts the socket to be lossless loses
messages, quietly, in exactly the situations users complain loudest about.

Validation through the existing `dry-validation` request schemas
(`app/request_schemas/`). Cap body length here, not only in the model.

---

## Ticket C — Staff REST API

### Proposed scope

Under `Api::V1::Admin`, inheriting `Admin::BaseController` so it picks up
`authenticate_user!` + `require_admin!` (which renders 404, not 403, so the
surface doesn't advertise itself) and `log_admin_action`:

```
GET   /api/v1/admin/conversations                  # inbox: filter by status, assignee, unread
GET   /api/v1/admin/conversations/:id
POST  /api/v1/admin/conversations/:id/messages     # reply
POST  /api/v1/admin/conversations/:id/assign       # claim / release
POST  /api/v1/admin/conversations/:id/resolve
POST  /api/v1/admin/conversations/:id/read
```

**Audit logging:** `assign` and `resolve` go through `log_admin_action`. Replies
deliberately do not — the message row *is* the audit trail, and duplicating every
reply into `admin_actions` would drown the moderation history that table exists
to make queryable.

The conversation detail response should include the Rally context that motivated
building rather than buying: the participant's recent registrations, payment
states, and any refunds. That context is the whole argument for in-house, so it
should land in v1, not "later".

---

## Ticket D — `ChatChannel` and broadcasts

### Proposed scope

- `ApplicationCable::Connection` — ticket auth from Ticket 0, `identified_by :current_user`.
- `ChatChannel`:
  - a participant may stream from their own conversation only;
  - an admin may stream from any conversation, plus a staff-wide `support:inbox`
    stream so a new thread lights up every open console.
  - Authorisation is checked in `subscribed`, and rejected with `reject` — the
    same "prove it per action" posture the controllers take, since there is no
    `before_action` equivalent here.
- Broadcast **after commit**, never inside the transaction that wrote the message.
  A broadcast from inside an open transaction can reach a subscriber that then
  reads the row before it is visible — a race that shows up as a client receiving
  a message id its own `GET /messages?after=` cannot find.
- Broadcast payloads carry the full message, so the happy path needs no follow-up
  fetch — but the client still reconciles against REST on reconnect.

~~Delete the `PingChannel` scaffolding from Ticket 0 here.~~ **Deferred.**
Ticket 0's cross-task fan-out check is still open: `terraform.tfvars` runs
`ecs_desired_count = 1`, so the smoke run proved Solid Cable's write → poll →
dispatch loop works (10,800 echoes delivered to all 30 subscribers) but could
not observe delivery *between* tasks, because there is only one. PingChannel is
the only tool that can answer that without posting real messages into real
conversations. Delete it once the check has been run at `desired_count = 2`.

---

## Ticket E — Participant UI

### Proposed scope

- A launcher button (bottom-right bubble, the conventional position) visible to
  signed-in users only, with an unread dot. Anonymous visitors never see it and
  never open a socket.
- A panel: message list, composer, "staff typically reply within…" empty state.
- **One hook owns the transport** — `useSupportChat` — wrapping: fetch ticket →
  open consumer → subscribe → on message, append; on reconnect, `GET
  /messages?after=<last id>` and merge. Components never touch ActionCable
  directly. This is also the seam that makes a fallback to polling a one-file
  change if operational reality turns out worse than Ticket 0's staging numbers.
- Connection state must be *visible*: a quiet "reconnecting…" line beats a
  composer that silently swallows messages. Optimistic send with a failed state
  and retry.
- Lazy-load the ActionCable consumer so visitors who never open chat don't pay
  for the bundle.
- i18n: every string through `t()`, **`en.json` and `km.json` in lockstep** — a
  missing Khmer key silently falls back to English.

---

## Ticket F — Staff console

### Proposed scope

- A fourth tab in `frontend/src/routes/_authenticated/admin.tsx`, which is already
  a `Tabs` layout with `overview` / `users` / `events` — the shape is there.
- Two-pane: conversation list (filters: open / mine / unassigned / resolved) and
  the selected thread with the participant-context sidebar from Ticket C.
- Subscribes to `support:inbox` for new-thread arrival; per-thread subscribe on open.
- At 723 lines, `admin.tsx` should not absorb this inline — extract the tab into
  its own component file and, if it's cheap, lift the existing tabs out too.

---

## Ticket G — Notifications and offline fallback

### Proposed scope

A staff reply must reach a participant who has closed the tab. Reuse what the
notification badge already built:

- New `Notification::KINDS` entry: `support_reply`.
- A `Notifications::SupportNotifier` sibling to `Notifications::RegistrationNotifier`.
  **Do not extend `RegistrationNotifier`** — its whole surface takes a
  `registration`, and a support thread has none. Same shape, different subject.
- Follow the established split: the in-app row is always written; push respects
  the user's preference.
- **Email fallback on a delay.** A job enqueued `perform_later(wait: 3.minutes)`
  that emails only if the participant still hasn't read the message. Chat without
  this is a black hole for anyone who walks away mid-conversation.
- Staff direction: new threads surface in the console badge. Admins are users, so
  the existing bell works for them for free.

---

## Ticket H — Rate limiting, retention, abuse

### Proposed scope

- ~~Message rate limiting must live in `ChatChannel`, not rack-attack.~~
  **No longer needed — Ticket D made both channels receive-only.** Clients send
  over REST and only *receive* over the socket, so there is no client-callable
  channel action to rate limit and the existing rack-attack throttles
  (`support_messages/user`, `support_conversation/user`) already cover every
  write path. Specs assert `action_methods` is empty on both channels; if
  anyone adds one, the throttling problem comes back with it and this budget
  line becomes real again.
- Server-side body length cap, enforced in the model as well as the schema.
- Suspended accounts cannot open or post — `authenticate_user!` already rejects
  them, so confirm with a spec rather than new code.
- **Retention policy, decided before launch, not after.** Support threads contain
  whatever participants choose to paste, which in a payments product means card
  complaints and personal details. Decide the window (12 months?), write the
  recurring job into `config/recurring.yml` alongside the existing hourly jobs,
  and reflect it in the privacy policy (`frontend/src/routes/privacy.tsx`).
- Confirm behaviour under `User#anonymize!` — a deleted account's messages must
  not keep rendering a real name in the staff console.

---

## Non-goals

Explicitly out of scope. Each is a plausible follow-up; none should quietly grow
into this series:

- **Organizer ↔ participant chat.** The obvious next feature and roughly doubles
  the permission model. Ticket A's schema does not preclude it, but nothing here
  should be built "generically" in anticipation.
- File and screenshot attachments. (Active Storage is already wired, so this is a
  real candidate for v1.1.)
- Typing indicators, read receipts on the participant side, canned responses,
  chatbot/LLM triage, SLA reporting, business-hours routing.
- Native mobile push for staff.
- Chat history export.

## Open questions

1. **How many staff, and are they concurrent?** If it is one or two people
   checking periodically, the assignment model in Ticket C can be much simpler —
   or dropped from v1.
2. **Expected volume?** This determines whether the `support:inbox` broadcast is
   fine as a firehose or needs filtering.
3. **Coverage hours,** and what the empty state promises when nobody is online.
   Cheap to add, embarrassing to omit — a chat box that implies a human is
   listening at 2am is worse than one that says when someone will be.
4. **Retention window** (Ticket H).
5. **Is `RAILS_MAX_THREADS` worth setting explicitly** in `infrastructure/ecs.tf`
   while we're in here? It's unset, so the whole system runs on `puma.rb`'s
   default of 3 by accident rather than by decision.
