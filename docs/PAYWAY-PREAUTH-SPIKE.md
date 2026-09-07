# Spike — PayWay pre-auth + split capture

Ticket B of the platform-payments series. Companion to
`docs/PLATFORM-PAYMENTS-REGULATORY-BRIEF.md` (Ticket A), which is with the
lawyer.

**Status: partially answered.** The go/no-go question is settled from ABA's
public documentation. The remaining questions need sandbox credentials, and the
harness to answer them in minutes is committed as
`backend/lib/tasks/payway_spike.rake`.

This spike is deliberately **not** blocked on the legal answer. §9 of the
regulatory brief makes that call: whether KHQR can be pre-authorised is a
technical capability question, and a "no" would re-scope the design regardless
of what counsel says.

---

## 1. The go/no-go: KHQR supports pre-auth

§8 of the regulatory brief listed "split supported, but **KHQR is capture-only**"
as a stop-and-rescope outcome — KHQR is how most Cambodian participants pay, so
a capture-only KHQR would break split-at-capture for the payment method that
matters.

ABA's pre-auth documentation lists supported payment methods as **ABA PAY,
KHQR, and Credit/Debit Card (Visa, Mastercard, JCB, UPI)**.

**KHQR is in the list. That outcome row is closed and the design survives.**

Confirm it against sandbox before anyone relies on it — a docs page is not a
successful transaction — but the risk has dropped from "may kill the series" to
"verify when keys arrive".

## 2. What else the docs settle

**A pre-auth is the Purchase API with `purchase_type: "pre-auth"`.** Not a
separate endpoint. `AbaPayway::Client#generate_qr` already sends every other
field for this call, and already carries a `payout` parameter — currently
hardcoded to `nil`, present in both the signed field list and the request body.
So the gateway plumbing for a split may largely exist already; what's missing is
knowing what to put in that slot.

**Unclaimed holds auto-cancel after 30 days by default**, returning the funds to
the payer. See §5 — this is the single most consequential constraint in the
document.

**Payout amounts are decimal floats** (`3.44`), not integer cents. Rally stores
money as `*_cents` integers everywhere; this is a conversion boundary, and
rounding at it needs deciding rather than defaulting.

## 3. What is not settled

| # | Question | Why the docs can't answer it |
|---|---|---|
| 1 | Plaintext structure of `beneficiaries` before encryption | Documented only as an opaque encrypted string; the pre-encryption shape is never shown |
| 2 | Is the split declared at purchase, at completion, or both? | Both `payout` (Purchase) and `beneficiaries` (completion) exist; their relationship is undocumented |
| 3 | Does completion's `merchant_auth` use the same payload keys as refund? | ABA's body-parameter tables don't render on the completion page |
| 4 | Is `beneficiaries` included in the `hash`, and where in the order? | Field order is load-bearing and undocumented for this call |
| 5 | Who pays the processing fee on a split, and is it reported per transaction? | Not in the API docs at all — likely a commercial question for ABA, not a technical one |
| 6 | Can `check-transaction` distinguish an authorised hold from a completed capture? | Status enum isn't documented for pre-auth states |

Question 6 is easy to overlook and expensive to get wrong: if the two states
aren't distinguishable in the API response, Rally can't reconcile them in
production either, and that shapes the whole ledger design.

## 4. Running the spike

Get sandbox credentials at <https://sandbox.payway.com.kh/register-sandbox/>,
then:

```sh
cd backend
export ABA_PAYWAY_MERCHANT_ID=... ABA_PAYWAY_API_KEY=...
export ABA_PAYWAY_RSA_PUBLIC_KEY="$(cat sandbox_public.pem)"
export ABA_PAYWAY_BASE_URL=https://checkout-sandbox.payway.com.kh
export SPIKE_AMOUNT_CENTS=1000 SPIKE_HOST_AMOUNT_CENTS=700
export SPIKE_BENEFICIARY_ACCOUNT=<host's ABA account>

bin/rails payway:spike:preauth                          # → prints QR + tran_id
bin/rails 'payway:spike:status[TRAN_ID]'                # after paying the QR
bin/rails 'payway:spike:complete[TRAN_ID]'              # plain capture first
bin/rails 'payway:spike:complete_with_payout[TRAN_ID]'  # then the split
```

Run the plain capture before the split. If the split fails you want to already
know whether completion itself works — otherwise a single failure has two
possible causes and you're debugging both at once.

Every guessed payload is overridable without editing code:
`SPIKE_PAYOUT_JSON`, `SPIKE_BENEFICIARIES_JSON`, `SPIKE_MERCHANT_AUTH_JSON`,
`SPIKE_HASH_BENEFICIARIES`. Iterating those **is** the spike. A rejection with
a specific error message is a finding worth recording, not a failed run.

The harness prints each plaintext before encrypting it, so a rejected attempt
can be reproduced exactly.

## 5. Consequences that already follow, whatever sandbox says

**The 30-day hold expiry rules out escrow-until-event.** Registration usually
opens months before an event. A hold placed at registration expires and returns
the money long before the event happens, so "hold the participant's funds until
the event is safely over" is not buildable on pre-auth. Capture has to happen
near registration, which means the host is paid before the event, which means
**a refund is necessarily a clawback against future payouts rather than a
reversal of money Rally still holds.** The clawback ticket isn't one option
among several — it's forced. Worth stating plainly before anyone re-litigates
escrow later in the series.

**`AbaPayway::Client.for_event` inverts.** Today it builds a client from the
*organization's* credentials, so registration money settles directly to the
host and Rally is never in the path. Under the proposed flow the participant
pays Rally: the pre-auth is created on **Rally's** merchant account and the
organization becomes a payout *beneficiary*. That's not a parameter change to
`for_event` — it's the opposite arrangement, and the method's whole reason for
existing goes away for registration payments. Expect this to be the largest
single diff in the series.

**`build_merchant_auth` needs generalizing.** It hardcodes
`{mc_id, tran_id, refund_amount}`. Completion almost certainly wants different
keys. The RSA chunking is reusable; the payload construction is not. The spike
re-implements the encryption locally rather than bending the production method
around a guess.

**Organization PayWay credentials may become dead weight.** If registration
money stops flowing through the host's own merchant account, then
`Organization#payway_merchant_id` / `payway_api_key` / `payway_rsa_public_key`
stop being needed for registrations, and what a host supplies instead is a
*beneficiary account number*. Don't drop the columns until the flow is live —
but don't build new features on them either.

## 6. Results — fill in when the keys arrive

| Test | Expected | Actual | Notes |
|---|---|---|---|
| Pre-auth on KHQR is accepted | `status.code` `"00"`, QR returned | | |
| Paying the QR leaves an authorised, uncaptured hold | | | Q6 above |
| `check-transaction` distinguishes hold from capture | | | |
| Plain completion captures the full amount | | | |
| Completion `merchant_auth` payload shape | `{mc_id, tran_id, amount}` (guess) | | |
| `beneficiaries` plaintext shape | JSON array (guess) | | |
| Split settles both legs | host + Rally amounts as sent | | |
| `beneficiaries` in the `hash` | excluded (guess) | | |
| Fee visibility on a split | | | May need ABA to answer |
| Cancellation releases the hold, and how fast | | | Participant-visible latency |

## 7. Still needs ABA, not sandbox

Sandbox can't answer the commercial questions. These stay in the email drafted
in §7 of the regulatory brief:

- Which party is debited the processing fee on a split, and at what rate
- What's required to whitelist a host as a payout beneficiary, and the typical
  approval turnaround — this becomes host onboarding latency, so it's a product
  constraint, not just an ops detail
- Settlement timing per leg
- Whether ABA supports the marketplace pattern contractually, not merely
  technically

## 8. Cleanup

`backend/lib/tasks/payway_spike.rake` is throwaway. Delete it once §6 is filled
in and the real implementation lands in `AbaPayway::Client`. It reaches into the
client's private methods via `#send`, which is acceptable in a spike and not
acceptable in anything that outlives one.

---

**Sources**

- [ABA PayWay — pre-authorisation](https://developer.payway.com.kh/)
- [ABA PayWay — refund API](https://developer.payway.com.kh/refund-api-14530821e0) (the RSA/`merchant_auth` pattern reused here)
- [PayWay sandbox registration](https://sandbox.payway.com.kh/register-sandbox/)
