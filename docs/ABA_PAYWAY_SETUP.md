# Setup guide: payments (ABA PayWay KHQR) & transactional email (AWS SES)

This covers the manual, one-time account setup needed for the payment and
email features added to Rally. Nothing here can be automated by Terraform or
the app itself — these are steps only you can do, since they require
verifying real-world identity/ownership with ABA Bank and AWS.

## 1. ABA PayWay (KHQR payments)

Rally collects payment for paid events via ABA KHQR — participants scan a
generated QR code (or tap "Open ABA Mobile") and pay through ABA Mobile or
any KHQR-participating bank app. The integration lives in
`backend/app/services/aba_payway/client.rb`.

### Get sandbox credentials (do this first)

1. Register for a sandbox account at **https://sandbox.payway.com.kh**.
2. ABA emails you a **Merchant ID** and **API Key** for the sandbox environment.
3. Set them locally in `backend/.env`:
   ```
   ABA_PAYWAY_MERCHANT_ID=your-sandbox-merchant-id
   ABA_PAYWAY_API_KEY=your-sandbox-api-key
   ```
   These two env vars are the only required setup — `backend/config/payway.yml`
   (one section per Rails environment, same pattern as `config/database.yml`)
   already pins the right `base_url` per environment (sandbox in
   development/test, live in production), so `ABA_PAYWAY_BASE_URL` is only
   needed if you want to override that, e.g. to point at a staging PayWay
   account.
4. Test a registration + payment end-to-end locally. Sandbox KHQR codes can be
   "paid" using ABA's sandbox test tools — check the developer docs at
   **https://developer.payway.com.kh** for the current sandbox testing flow,
   since ABA occasionally changes how sandbox payments are simulated.

### Go to production

1. Once you're ready to accept real money, email **paywaysales@ababank.com**
   to request production credentials (they'll typically ask for your business
   registration and a working sandbox integration first).
2. **Whitelist your domain.** ABA requires your production domain/IP to be
   pre-approved — requests from an un-whitelisted domain fail with error code
   `6`. Give ABA your `api_domain` (the backend's public domain).
3. Put the production Merchant ID / API key into `terraform.tfvars`:
   ```hcl
   aba_payway_merchant_id = "..."
   aba_payway_api_key     = "..."
   ```
   `aba_payway_base_url` is optional now — `config/payway.yml` already
   defaults production to `https://checkout.payway.com.kh`. Only set it if
   you need to override that.
4. Run `terraform apply` — this writes the credentials to AWS Secrets
   Manager and injects them into the ECS task (see `infrastructure/secrets.tf`,
   `infrastructure/iam.tf`, `infrastructure/ecs.tf`).

### Important: the webhook needs HTTPS, and that needs a custom domain

ABA requires the payment webhook (`callback_url`) to be served over HTTPS.
The ECS/ALB setup only terminates HTTPS when `api_domain` +
`route53_zone_id` are set in `terraform.tfvars` (see the main
`terraform.tfvars.example` for how to configure a custom domain). Without a
custom domain, the app falls back to the ALB's plain HTTP URL for
`BACKEND_URL`, and ABA's webhook calls will not reach it.

This isn't a hard blocker: `PaymentsController#show` (used by the frontend's
polling) independently re-checks payment status with ABA's Check Transaction
API whenever a payment is still pending, so payments still get confirmed —
just a few seconds slower, on the next poll, instead of instantly via
webhook. But for production you should set up a custom API domain so the
webhook path works as intended.

### How the integration works, briefly

- `POST /api/v1/registrations/:id/payments` creates a `Payment` row and asks
  ABA to generate a KHQR code (`generate-qr`). The amount is always computed
  server-side from the registration's event/event-type pricing — the
  frontend never tells the backend how much to charge.
- The frontend renders the returned `qr_string` as a QR code and polls
  `GET /api/v1/payments/:id` every few seconds.
- ABA's webhook (`POST /api/v1/webhooks/aba_payway`) is a *trigger only* — on
  receipt, the backend independently calls ABA's Check Transaction API to
  confirm the real status before marking anything paid, since the webhook
  payload itself isn't cryptographically signed. The same re-check logic
  also runs from the polling endpoint, so both paths converge on the same
  verification step.
- Currency: USD amounts are sent with 2 decimal places; KHR amounts are sent
  as whole numbers (no decimals), per ABA's requirements.

## 2. Transactional email (Amazon SES)

Registration confirmations, payment receipts, password resets, and email
verification all send through Amazon SES (`config/environments/production.rb`,
`app/mailers/`). No SMTP credentials are needed — the ECS task's IAM role has
`ses:SendEmail` permission (see `infrastructure/iam.tf`), so the AWS SDK
picks up credentials automatically.

### One-time setup

1. **Verify a sending identity in SES.** In the AWS Console → SES → Verified
   identities, verify either a single email address (quick, fine for testing)
   or your whole domain (recommended — lets you send from any
   `@yourdomain.com` address and improves deliverability with DKIM). Domain
   verification requires adding DNS records, which you can do via Route 53
   if that's already managing your zone.
2. **Set the from address.** Put a verified address in `terraform.tfvars`:
   ```hcl
   mailer_from_email = "Rally <no-reply@yourdomain.com>"
   ```
3. **Request production access.** New SES accounts start in the *sandbox*,
   which only allows sending to addresses you've manually verified — real
   users won't receive anything until you request production access from
   AWS (Console → SES → Account dashboard → "Request production access").
   This is a support request AWS reviews manually; do this early, it's not
   instant.
4. Run `terraform apply` to pick up the new `mailer_from_email` value.

### Local development

Rails' default (unconfigured) mailer setup in development will try to
connect to `localhost:25` and silently fail (`raise_delivery_errors` isn't
set, so nothing breaks — you just won't see the email). If you want to
actually see outgoing emails while developing, either:

- Check `Rails.logger` — mailer bodies are logged even when delivery fails, or
- Point `config.action_mailer.delivery_method` at `:letter_opener` (add the
  `letter_opener` gem) or a local SMTP catcher like Mailhog, or
- Temporarily set the same SES env vars locally and use your own verified
  sandbox SES identity.

None of this blocks testing the rest of the flow — request specs run against
the `:test` delivery method regardless of what's configured for development.
