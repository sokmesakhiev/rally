# Notifications: three channels, one notifier

Loaded on demand — see the trigger table in CLAUDE.md. Everything here is
hard-won detail about *why* the code is shaped the way it is; it was moved out
of CLAUDE.md verbatim, not rewritten.

### Notifications: three channels, one notifier

`Notifications::RegistrationNotifier` is the single place the wording of each participant-facing event lives. It writes an in-app `Notification` row (what the header bell counts) and enqueues a web push; the `RegistrationMailer` call stays at the trigger site. `payment_received` alone fires from two paths — the polling endpoint and the ABA webhook — which is why the copy isn't inlined at call sites.

**Preferences diverge by channel, deliberately.** The notifier is called *outside* the caller's `wants_notification?` guard, unlike the mailer. Push respects `notify_*` exactly as email does — both are interruptions. The **in-app row is always written**: the bell is something you go and look at, and suppressing it would leave someone who muted payment emails with no way to discover their payment cleared. There's a spec pinning both halves.

"Real time" for the badge is two mechanisms, not one: `public/sw.js` posts a `rally:notification` message to open tabs when a push arrives, which invalidates the react-query cache immediately, plus a 60-second poll for everyone who declined permission or is on a browser without push. **Deliberately not SSE or long-polling** — production runs `RAILS_MAX_THREADS=3` on a **single** ECS task (`infrastructure/terraform.tfvars` sets `ecs_desired_count = 1`; `variables.tf` merely *defaults* to 2), so three request threads is the whole budget and a held-open Rack response per user would saturate it at single-digit concurrency. Moving Solid Queue to its own service freed CPU in that task but not threads — the three are still the ceiling. ActionCable is a different shape and is now loaded — it hijacks the socket off Puma's threads, so open connections don't consume request capacity. See "Backend: ActionCable" above.
