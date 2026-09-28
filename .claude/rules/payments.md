# Payments: ABA PayWay / KHQR

Loaded on demand — see the trigger table in CLAUDE.md. Everything here is
hard-won detail about *why* the code is shaped the way it is; it was moved out
of CLAUDE.md verbatim, not rewritten.

### Backend: publishing & payments (ABA PayWay / KHQR)

Two separate payment flows share one gateway (`app/services/aba_payway/client.rb`), and it's easy to conflate them:

- **`Payment`** — an attendee paying to register for an event. Created per-`Registration`.
- **`EventPlanPayment`** — an organizer paying Rally to *publish* an event under one of `Event::PLANS` (`free`/`small`/`medium`/`large`/`extra_large`, each with a fixed `capacity` and `price_cents`). `EventPlanPayment#mark_paid!` is what actually sets `event.is_published = true` and stamps the event's `plan`/`capacity`. The free tier publishes immediately with no pending payment to poll.

Gateway credentials are two-tiered:

- **Platform defaults** live in `config/payway.yml` (per-environment, `ERB`-evaluated, same `Rails.application.config_for` pattern as `config/database.yml`) — these are Rally's own PayWay account and are what `EventPlanPayment`s always use, and what `Payment`s fall back to.
- **Per-organizer credentials** live encrypted on `Profile` (`payway_merchant_id` / `payway_api_key`, via Active Record encryption). When `Profile#payway_configured?` is true, that organizer's own event registration payments route through their credentials instead of the platform default — see `AbaPayway::Client.for_event`. `ProfilesController#profile_json` only ever exposes `payway_api_key_masked`, never the real key.
