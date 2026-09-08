# Platform payments — regulatory brief

Prepared 2026-09-06 to support the first ticket in `platform-payments-tickets.md`.

**This is not legal advice.** It's a briefing to make two conversations — one
with ABA, one with a Cambodian lawyer — short and productive. Every finding
below needs confirming by someone qualified before it's relied on.

---

## 1. What Rally does today

An attendee pays for a registration. `AbaPayway::Client.for_event` builds a
PayWay client from **the organizing organization's own merchant credentials**
(`Organization#payway_merchant_id` / `payway_api_key`, encrypted at rest).

The money moves **from the participant directly into the host's ABA merchant
account**. Rally never holds, routes, or touches participant funds.

Rally's only revenue today is a **publish fee** — the organizer pays Rally to
publish an event under a capacity plan (`EventPlanPayment`). That charge runs
through Rally's own PayWay account and is a straightforward
merchant-to-customer sale of Rally's own service.

Refunds are issued by calling PayWay's Refund API **against the host's own
transaction, using the host's own credentials**.

## 2. What's proposed

The participant pays **Rally**. Rally takes a commission and passes the
remainder to the host.

Mechanically, the intended design is **split-at-capture**:

1. Registration pre-authorises the participant's payment
2. Capture uses PayWay's *complete pre-auth with payout*, which splits inside
   PayWay — commission settles to Rally, remainder to the host

The deliberate property is that **funds never rest in a Rally-controlled
balance**. There is no escrow account and no float. This was chosen
specifically to keep the regulatory exposure as small as the feature allows.

Refunds become Rally's obligation: Rally refunds the participant, then recovers
the host's share from future payouts (the clawback ticket).

## 3. Why this needs an answer before any code

The change isn't "which API do we call". It's that Rally moves from *not being
in the payment path at all* to *being the party the participant pays*. That's
a different regulatory position even though no money sits still.

## 4. What the research suggests (verify all of this)

Two NBC instruments look relevant:

**Prakas on the Management of Payment Service Providers (14 June 2017)** makes
providing payment services through payment transaction accounts a licensed
activity, requiring NBC approval. Reported licensing thresholds include a
**minimum US$2 million in reserves**, plus depositing 5% of registered share
capital with NBC. If that applies to Rally, it is almost certainly
prohibitive at this stage.

**Prakas on Third-Party Processors (25 August 2010)** is the more promising
path. A third-party processor acts *on behalf of a bank*, and must
**"tie-in" with a banking institution**. The distinction reported in the
sources is that a third-party processor facilitates a bank's payment
transactions, whereas a payment service provider is independent.

**The single most valuable question is therefore whether Rally can operate as
a third-party processor tied to ABA, rather than as an independent payment
service provider.** Rally already has an ABA relationship, and the split
happens inside PayWay rather than in a Rally-held balance — which at least
resembles facilitating ABA's payment transactions rather than performing
Rally's own. Whether that reading survives contact with the actual Prakas is
exactly what the lawyer is for.

## 5. Questions for ABA

Send to **paywaysales@ababank.com** (the address in ABA's developer docs), or
your existing merchant contact if you have one. Draft email in §7.

1. Can a marketplace platform use *complete pre-auth with payout* to split a
   single participant payment between the platform's own merchant account and
   a host's merchant account?
2. What does ABA require of the platform to enable multi-party payouts —
   contract type, merchant category, documentation, minimum volumes?
3. **Does KHQR support pre-authorisation, or only immediate capture?** This
   decides whether the design works at all for the payment method most
   participants use.
4. Beneficiary whitelisting: what does a host have to provide, what's the
   typical approval turnaround, and can it be submitted through the API or
   only manually?
5. Who is debited the processing fee on a split transaction, and is the fee
   visible per transaction in the API response?
6. On refunds: can the platform refund a captured split transaction in full,
   and what happens to the portion already settled to the host?
7. Does ABA consider this arrangement to place Rally under the
   third-party-processor framework, and would ABA sponsor that tie-in?
8. What settlement timing applies to each leg of a split?

## 6. Questions for the lawyer

Give them §1 and §2 verbatim — the distinction between today's flow and the
proposed one is the whole question.

1. Under the 2017 PSP Prakas, does Rally collecting a participant payment and
   splitting it — with no float, settlement handled inside ABA — constitute
   providing a payment service requiring a licence?
2. If yes, is the third-party-processor route under the 2010 Prakas available
   instead, given Rally would be tied to ABA?
3. Does the answer change because Rally never holds a balance? Is "no float"
   legally meaningful here, or does being the payee at checkout settle it
   regardless?
4. **Does the clawback flow change the analysis?** Rally refunds the
   participant from its own funds and then recovers from the host. That's
   Rally extending short-term credit to a host — does that carry its own
   licensing implication?
5. What consumer-protection obligations attach to Rally once it's the payee —
   mandatory refund rights, disclosure, complaint handling?
6. Does taking a commission on the participant's payment change Rally's tax
   position (VAT on the commission, withholding on host payouts)?
7. What must change in Rally's Terms of Service? Note these are **still
   unreviewed placeholder text** — see `docs/GO-LIVE-READINESS.md` — so this
   is a good moment to deal with both at once.

## 7. Draft email to ABA

> **Subject:** Multi-party payout / split payment for an event registration platform
>
> Hello,
>
> We operate Rally, an event registration platform in Cambodia. We currently
> integrate ABA PayWay, with each event organizer using their own PayWay
> merchant credentials so that registration payments settle directly to them.
>
> We're evaluating a change where the participant pays Rally, and the payment
> is split so that our commission settles to our merchant account and the
> remainder settles to the organizer's. From your developer documentation, we
> believe *Complete pre-auth transaction with payout* plus the Payout API's
> beneficiary whitelisting is the intended mechanism, and we'd like to confirm
> that before building anything.
>
> Specifically:
>
> 1. Is this split-at-capture pattern supported for a marketplace platform, and
>    what does ABA require from us to enable it?
> 2. Does KHQR support pre-authorisation, or is it capture-only? Most of our
>    participants pay by KHQR, so this materially affects the design.
> 3. What is required to whitelist an organizer as a payout beneficiary, and
>    what is the typical approval turnaround?
> 4. On a split transaction, which party is debited the processing fee, and is
>    it reported per transaction?
> 5. If we refund a captured split transaction, what happens to the portion
>    already settled to the organizer?
> 6. Would this arrangement place us under the third-party-processor framework,
>    and is that something ABA sponsors?
>
> We have a sandbox account and are happy to prototype against it once we know
> the intended approach.
>
> Thank you,
> [name] — Rally

## 8. What each answer means for the roadmap

| Outcome | Consequence |
|---|---|
| TPP route available via ABA | Proceed. Best case — the series runs as scoped. |
| Full PSP licence required | Stop. US$2M reserves is likely out of reach; keep the current direct-to-organizer model and revisit at scale. |
| Split supported, but **KHQR is capture-only** | Split-at-capture doesn't work for the dominant payment method. Re-open the fund-flow decision before anything else. |
| ABA won't support marketplace splits | The whole series is blocked on the gateway, not the law. Consider whether a different acquirer is worth the migration. |

## 9. Meanwhile

The spike ticket is blocked on the outcome above, but its **KHQR pre-auth
question can be answered from sandbox in parallel** — it's a technical
capability question, not a legal one. If the answer is "capture-only", that's
worth knowing before the lawyer's invoice arrives, because it re-scopes the
design regardless of what the legal answer turns out to be.

---

**Sources** (all need verification by counsel — these are secondary summaries,
not the Prakas themselves):

- [NBC — Payment Service Institutions](https://www.nbc.gov.kh/english/supervision/payment_service.php)
- [NBC — Prakas on Third-Party Processors (PDF)](https://www.nbc.gov.kh/download_files/legislation/prakas_eng/47.pdf)
- [Conventus Law — NBC introduces new regulation on Payment Service Providers](https://conventuslaw.com/report/cambodia-the-national-bank-of-cambodia-introduces/)
- [ZICO — Legal alert on the PSP Prakas](http://zico.group/blog/legal-alert-cambodia-national-bank-cambodia-introduces-new-regulation-payment-service-providers/)
- [National Trade Repository — Prakas on the Management of Payment Service Institution](https://cambodiantr.gov.kh/en/document/?title=prakas-on-the-management-of-payment-service-institution)
- [ABA PayWay developer documentation](https://developer.payway.com.kh/)
