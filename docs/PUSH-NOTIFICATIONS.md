# Push notifications

Web push, added by the push-notifications ticket in
`registration-engagement-tickets.md`.

Push runs **alongside** the existing mailers, never instead of them. Email
reaches everyone; push reaches the subset who opted in on a device. Nothing a
participant needs to know should arrive only by push.

## Setup

Generate a VAPID keypair once, and treat it as long-lived:

```sh
cd backend
bundle exec ruby -rwebpush -e 'puts WebPush.generate_key.to_h'
```

Set on the backend (`.env` locally, `infrastructure/secrets.tf` in production):

```
VAPID_PUBLIC_KEY=...
VAPID_PRIVATE_KEY=...
VAPID_SUBJECT=mailto:admin@rails-dev.com   # optional; defaults from MAILER_FROM_EMAIL
```

The frontend needs nothing. The public key is fetched at runtime from
`GET /api/v1/push/vapid_public_key`, not compiled in as a `VITE_` var — the
SPA is built once and cached on CloudFront, so a baked-in key could only change
with a rebuild plus an invalidation, and would silently disagree with the
backend in between.

**Unset means cleanly off.** With no keypair the API reports
`enabled: false`, the frontend hides the feature entirely, and
`Notifications::PushAdapters::Null` logs instead of sending. That's the state
in development, test and CI, and it's why no spec needs a keypair.

**Rotating the keypair invalidates every existing subscription.** Browsers tie
a subscription to the public key it was created with; every device silently
stops receiving notifications and must re-subscribe. There is no migration
path — treat rotation as a last resort.

## Deployment: the service worker must not be cached

`frontend/public/sw.js` is copied verbatim to the root of `dist/client/` and
synced to S3. It **must** be served with `Cache-Control: no-cache`.

Browsers re-fetch the service worker to check for updates. If CloudFront serves
a cached copy, the worker on people's devices can never be replaced — a bug in
the push handler becomes permanent for anyone who has already visited. Every
other asset is content-hashed and safe to cache forever; this one file is the
exception.

It also has to sit at the origin root. A service worker's default scope is its
own directory, so `/assets/sw.js` could only ever control `/assets/*`.

## How it fits together

```
trigger point  ──▶ Notifications::RegistrationPush  (payload wording, one place)
                        │
                        ▼
               SendPushNotificationJob              (async — a browser vendor's
                        │                            latency stays out of the
                        ▼                            request cycle)
               Notifications::DeliverPush           (fan out to the user's live
                        │                            subscriptions)
                        ▼
        PushAdapters::WebPush | PushAdapters::Null
```

The adapter seam exists so a native app (FCM/APNs) can be added as a sibling
class rather than by rewriting every call site. That was the explicit scoping
decision: web push only for now, but don't paint the sending path into a
corner.

### Trigger points

Push fires from the same three places their mailers already do, with the same
preference checks, so nobody ends up silenced on one channel and not the other:

| Trigger | Preference | Where |
|---|---|---|
| Registration confirmed | none — transactional, like the email | `RegistrationsController#create` |
| Payment received | `notify_payment_received` | `PaymentsController`, `ProcessAbaPaywayWebhookJob` |
| Promoted from waitlist | `notify_promoted_from_waitlist` | `Waitlists::PromoteNext` |

Confirmation is unconditional because the confirmation **email** is: there is
no `notify_confirmation` column, and adding one would change existing email
behaviour, which is transactional by design. The subscription itself is already
an opt-in.

`payment_received` fires from two paths — the polling endpoint and the ABA
webhook — which is why the payload wording lives in
`Notifications::RegistrationPush` rather than being copied to each site.

## Endpoints

| | |
|---|---|
| `GET /api/v1/push/vapid_public_key` | Unauthenticated — the browser needs the key before it can subscribe. |
| `POST /api/v1/push/subscriptions` | Idempotent by endpoint; also un-expires a revived device. |
| `POST /api/v1/push/unsubscribe` | A POST, not a DELETE — see below. |

Unsubscribing is a `POST` because the endpoint has to travel in a request
body. It can't go in the path (a URL nested in a URL) and shouldn't go in a
query string (a specific person's device address, written to every access log
between the browser and Puma) — but bodies on `DELETE` aren't reliably parsed
end to end, by Rails or by intermediaries. `POST` removes the ambiguity.

### Subscriptions are per device, and can change hands

A push endpoint identifies a **browser and VAPID key**, not a person. On a
shared device, the second person to sign in and subscribe gets the *same*
endpoint back from the browser, and genuinely owns it — there is one device,
and it is now theirs.

So `#create` transfers the row rather than rejecting it, deliberately and with
a log line. Note what that does and doesn't buy: the subscription keys are
taken on trust, so anyone who learns an endpoint can still claim it. The
residual risk is a denial of service — the victim's device stops receiving
their notifications and starts receiving the claimant's — not exfiltration,
since nothing flows back to the caller. Endpoints are high-entropy vendor URLs
exposed only to their own owner. If that changes, the answer is proof of
possession, not blocking the transfer.

`#unsubscribe`, by contrast, is scoped strictly to the caller's own rows:
knowing an endpoint must never be enough to silence someone else's device.

## Asking for permission

The prompt is tied to an explicit click, in `PushNotificationPrompt`, shown
after a successful registration. Never on page load.

This is not politeness. Chrome and Firefox both suppress the prompt outright
for users who habitually dismiss it, and a denial is close to unrecoverable —
there's no API to ask again, the user has to find it in site settings. Asking
at the one moment the value is concrete ("tell me when my payment clears")
rather than abstract is the difference between a granted permission and a
permanently blocked one.

The component renders nothing when the browser can't do push, the server has
no keypair, permission was already denied, or the device is already subscribed.

## Known gaps

- **Copy is English only.** The mailers aren't localized either, and there's no
  stored user locale to translate against. Worth doing together, not separately.
- **`pushsubscriptionchange` unregisters the worker** rather than re-subscribing
  in place. The service worker has no session to call our authenticated API
  with, so the page re-syncs on next load. A device whose subscription rotates
  goes quiet until then.
- **iOS Safari needs an installed PWA** for web push, and there's no manifest
  yet — so iPhone users can't subscribe at all. Adding `manifest.json` is the
  prerequisite if that matters.
- **No `icon-192.png`.** `sw.js` references one for the notification icon;
  without it browsers fall back to a generic bell.
