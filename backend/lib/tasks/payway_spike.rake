# frozen_string_literal: true

# Spike harness for platform-payments Ticket B — pre-auth + split capture
# against the ABA PayWay sandbox.
#
# DELETE THIS FILE once the findings are recorded in
# docs/PAYWAY-PREAUTH-SPIKE.md. It exists to answer questions, not to become
# production code — the real implementation belongs in AbaPayway::Client,
# shaped by whatever this turns up.
#
# It deliberately does NOT modify AbaPayway::Client. That client moves real
# money today; borrowing its private helpers via #send for a throwaway
# experiment is the smaller risk.
#
#   Setup — sandbox credentials from https://sandbox.payway.com.kh/register-sandbox/
#     export ABA_PAYWAY_MERCHANT_ID=...
#     export ABA_PAYWAY_API_KEY=...
#     export ABA_PAYWAY_RSA_PUBLIC_KEY="$(cat sandbox_public.pem)"   # completion/payout only
#     export ABA_PAYWAY_BASE_URL=https://checkout-sandbox.payway.com.kh
#
#   Walk it through in order:
#     bin/rails payway:spike:preauth                        # create the hold, print the QR
#     bin/rails 'payway:spike:status[TRAN_ID]'              # poll until it shows as authorised
#     bin/rails 'payway:spike:complete[TRAN_ID]'            # capture, no split
#     bin/rails 'payway:spike:complete_with_payout[TRAN_ID]'  # capture WITH split — the question
#     bin/rails 'payway:spike:cancel[TRAN_ID]'              # release the hold
#
#   For the split leg, also set the destination:
#     export SPIKE_BENEFICIARY_ACCOUNT=000000000   # the host's ABA account
#     export SPIKE_HOST_AMOUNT_CENTS=700           # host's share; the rest is Rally's commission
#
# WHAT THE PUBLIC DOCS ALREADY SETTLE (so nobody re-derives it):
#
#   * KHQR DOES support pre-auth. ABA lists "ABA PAY, KHQR, Credit/Debit Card
#     (Visa, Mastercard, JCB, UPI)" as supported payment methods for pre-auth.
#     That was the go/no-go for split-at-capture on our dominant payment
#     method, and it clears — see §8 of the regulatory brief, which had
#     "KHQR is capture-only" as a stop-and-rescope outcome.
#   * A pre-auth is just the Purchase API with purchase_type "pre-auth".
#     AbaPayway::Client#generate_qr already sends every other field — and
#     already has a `payout` slot sitting at nil.
#   * Unclaimed holds auto-cancel after 30 days by default. That is the hard
#     ceiling on any "hold the funds until the refund window closes" variant.
#
# WHAT IT DOES NOT SETTLE — this harness exists to find out:
#
#   1. The plaintext shape of `payout` / `beneficiaries` before encryption.
#      ABA renders it as an opaque encrypted string and never shows what goes
#      in. SPIKE_PAYOUT_JSON and SPIKE_BENEFICIARIES_JSON are the knobs for
#      guessing; varying them IS the spike.
#   2. Whether the split is declared at purchase time (Purchase's `payout`
#      field), at completion, or both.
#   3. Whether merchant_auth for completion uses the same payload keys as
#      refund. AbaPayway::Client#build_merchant_auth hardcodes
#      {mc_id, tran_id, refund_amount} — almost certainly wrong for a
#      completion, which is why this file re-implements the encryption rather
#      than calling that method. SPIKE_MERCHANT_AUTH_JSON overrides it.
#   4. Who is debited the processing fee on a split, and whether it's
#      reported per transaction.

module PaywaySpike
  # Defined as a module rather than bare `def`s in the rake namespace: a
  # top-level `def sign` in a .rake file becomes a private method on Object,
  # visible to every other task in the app. Generic names like `sign` and
  # `report` are exactly the ones that would collide.
  module_function

  def client
    @client ||= AbaPayway::Client.new
  end

  def merchant_id
    ENV.fetch("ABA_PAYWAY_MERCHANT_ID")
  end

  # The production client keeps these private, correctly — nothing outside it
  # should be hand-rolling PayWay auth. A spike is the exception that proves it.
  def sign(*parts)
    client.send(:sign, *parts)
  end

  def post_json(path, body)
    client.send(:post_json, path, body)
  end

  def now
    client.send(:format_time, Time.now.utc)
  end

  def amount(cents, currency = self.currency)
    client.send(:format_amount, cents, currency)
  end

  def currency
    ENV.fetch("SPIKE_CURRENCY", "USD").upcase
  end

  # Fail fast and legibly on missing credentials. Without this, an absent
  # api_key surfaces as an OpenSSL error from deep inside #sign.
  def check_credentials!
    client.send(:ensure_configured!)
  end

  # Same chunked PKCS#1 v1.5 RSA as AbaPayway::Client#build_merchant_auth, but
  # over an arbitrary payload. Re-implemented rather than reused because that
  # method hardcodes the refund payload's keys, and the whole point here is to
  # vary them. PKCS1 (not OAEP) matches ABA's PHP reference — see the long
  # comment on #build_merchant_auth before "fixing" this.
  def rsa_encrypt(payload)
    key = ENV.fetch("ABA_PAYWAY_RSA_PUBLIC_KEY")
    rsa = OpenSSL::PKey::RSA.new(key)
    chunk_size = AbaPayway::Client::REFUND_ENCRYPTION_CHUNK_SIZE

    encrypted = +""
    remaining = payload.dup
    until remaining.empty?
      chunk = remaining.byteslice(0, chunk_size)
      remaining = remaining.byteslice(chunk_size..) || ""
      encrypted << rsa.public_encrypt(chunk, OpenSSL::PKey::RSA::PKCS1_PADDING)
    end

    Base64.strict_encode64(encrypted)
  end

  # merchant_auth for a completion. GUESS: same envelope as refund, with
  # `amount` in place of `refund_amount`. Override wholesale with
  # SPIKE_MERCHANT_AUTH_JSON when iterating.
  def merchant_auth(tran_id:, amount_str:)
    payload = ENV.fetch("SPIKE_MERCHANT_AUTH_JSON") do
      { mc_id: merchant_id, tran_id: tran_id, amount: amount_str }.to_json
    end
    puts "  merchant_auth plaintext: #{payload}"
    rsa_encrypt(payload)
  end

  def report(label, payload)
    puts "\n== #{label} =="
    puts JSON.pretty_generate(payload.as_json)
    puts
  end

  # Anything PayWay rejects comes back as a non-"00" status in a 200 response,
  # not an exception — same as the refund path. Print it and move on rather
  # than letting a RequestError hide the body we actually want to read.
  def attempt(label)
    report(label, yield)
  rescue AbaPayway::Error => e
    puts "\n!! #{label} FAILED: #{e.class} — #{e.message}"
    puts "   Record the exact message; a rejected guess is a finding."
  end
end

namespace :payway do
  namespace :spike do
    desc "Create a pre-auth (hold) and print the KHQR to pay in sandbox"
    task preauth: :environment do
      spike = PaywaySpike
      spike.check_credentials!

      tran_id = ENV.fetch("SPIKE_TRAN_ID") { "spk#{SecureRandom.alphanumeric(14)}" }
      amount_cents = Integer(ENV.fetch("SPIKE_AMOUNT_CENTS", "1000"))
      amount = spike.amount(amount_cents)
      req_time = spike.now

      # Test 2 from the findings doc: does the split declare at purchase time?
      # Leave SPIKE_PAYOUT_JSON unset for the first run — confirm a plain
      # pre-auth works before adding a second variable to it.
      payout = ENV["SPIKE_PAYOUT_JSON"].presence
      purchase_type = "pre-auth"
      payment_option = "abapay_khqr"
      lifetime = 15
      qr_image_template = "template3_color"

      # Field order MUST match AbaPayway::Client#generate_qr's #sign call
      # exactly. PayWay's hash is order-sensitive and a mismatch returns a
      # generic auth failure that says nothing about which field moved — so
      # the nils are load-bearing placeholders, not noise. In order:
      # items, first_name, last_name, email, phone / then after currency:
      # custom_fields, return_params.
      hash = spike.sign(
        req_time, spike.merchant_id, tran_id, amount, nil, nil, nil, nil, nil,
        purchase_type, payment_option, nil, nil, spike.currency,
        nil, nil, payout, lifetime, qr_image_template
      )

      spike.attempt("PRE-AUTH CREATED — tran_id #{tran_id}") do
        spike.post_json(AbaPayway::Client::GENERATE_QR_PATH, {
          req_time: req_time, merchant_id: spike.merchant_id, tran_id: tran_id,
          amount: amount, currency: spike.currency,
          payment_option: payment_option, purchase_type: purchase_type,
          payout: payout, lifetime: lifetime,
          qr_image_template: qr_image_template, hash: hash
        }.compact)
      end

      puts "Pay the QR above in the sandbox app, then:"
      puts "  bin/rails 'payway:spike:status[#{tran_id}]'"
      puts "Keep SPIKE_AMOUNT_CENTS=#{amount_cents} exported — completion must match."
    end

    desc "Check a spike transaction's current status"
    task :status, [ :tran_id ] => :environment do |_t, args|
      spike = PaywaySpike
      tran_id = args.fetch(:tran_id)

      spike.attempt("STATUS — #{tran_id}") { spike.client.check_transaction(tran_id: tran_id) }

      puts "Record: transaction_status, and whether an authorised-but-uncaptured"
      puts "hold is distinguishable from a completed purchase in this response."
      puts "If it isn't, we can't tell the two apart in production either —"
      puts "which is a finding that affects the whole reconciliation design."
    end

    desc "Complete (capture) a pre-auth WITHOUT a split — proves the plain path first"
    task :complete, [ :tran_id ] => :environment do |_t, args|
      spike = PaywaySpike
      spike.check_credentials!

      tran_id = args.fetch(:tran_id)
      amount_cents = Integer(ENV.fetch("SPIKE_AMOUNT_CENTS", "1000"))
      amount = spike.amount(amount_cents)
      req_time = spike.now
      merchant_auth = spike.merchant_auth(tran_id: tran_id, amount_str: amount)
      hash = spike.sign(req_time, spike.merchant_id, merchant_auth)

      spike.attempt("COMPLETED (no split) — #{tran_id}") do
        spike.post_json(
          "/api/merchant-portal/merchant-access/online-transaction/pre-auth-completion",
          { request_time: req_time, merchant_id: spike.merchant_id,
            merchant_auth: merchant_auth, hash: hash }
        )
      end
    end

    desc "Complete a pre-auth WITH a payout split — the question this spike exists for"
    task :complete_with_payout, [ :tran_id ] => :environment do |_t, args|
      spike = PaywaySpike
      spike.check_credentials!

      tran_id = args.fetch(:tran_id)
      total_cents = Integer(ENV.fetch("SPIKE_AMOUNT_CENTS", "1000"))
      host_cents = Integer(ENV.fetch("SPIKE_HOST_AMOUNT_CENTS", "700"))

      total = spike.amount(total_cents)
      host_amount = spike.amount(host_cents)
      puts "Split: total #{total} #{spike.currency} → host #{host_amount}, " \
           "Rally keeps #{spike.amount(total_cents - host_cents)}"

      # THE UNKNOWN. ABA documents `beneficiaries` only as an encrypted string.
      # This guesses it's the same chunked-RSA envelope as merchant_auth, over
      # a JSON array. Note the payout response returns amounts as decimal
      # FLOATS (e.g. 3.44), not integer cents — so a codebase that stores cents
      # everywhere has a conversion boundary here. Sending them as formatted
      # strings is itself part of the guess.
      # SPIKE_BENEFICIARY_ACCOUNT is only read when building the default shape —
      # if you're overriding the whole payload, you shouldn't also have to set
      # a variable that no longer feeds into it.
      beneficiaries_payload = ENV.fetch("SPIKE_BENEFICIARIES_JSON") do
        [ { account: ENV.fetch("SPIKE_BENEFICIARY_ACCOUNT"), amount: host_amount } ].to_json
      end
      puts "  beneficiaries plaintext: #{beneficiaries_payload}"

      req_time = spike.now
      merchant_auth = spike.merchant_auth(tran_id: tran_id, amount_str: total)
      beneficiaries = spike.rsa_encrypt(beneficiaries_payload)

      # Whether `beneficiaries` belongs in the hash — and if so, where in the
      # order — is unknown. Try it excluded first (below); if that's rejected,
      # re-run with SPIKE_HASH_BENEFICIARIES=1.
      hash = if ENV["SPIKE_HASH_BENEFICIARIES"].present?
        spike.sign(req_time, spike.merchant_id, merchant_auth, beneficiaries)
      else
        spike.sign(req_time, spike.merchant_id, merchant_auth)
      end

      spike.attempt("COMPLETED WITH PAYOUT — #{tran_id}") do
        spike.post_json(
          "/api/merchant-portal/merchant-access/online-transaction/pre-auth-completion",
          { request_time: req_time, merchant_id: spike.merchant_id,
            merchant_auth: merchant_auth, beneficiaries: beneficiaries, hash: hash }
        )
      end

      puts "Record: the per-beneficiary payout_id / mid_acccount / amount in the"
      puts "response (ABA's own typo on mid_acccount), each leg's settled amount,"
      puts "and whether any fee is visible anywhere in the payload."
    end

    desc "Cancel (release) a pre-auth hold"
    task :cancel, [ :tran_id ] => :environment do |_t, args|
      spike = PaywaySpike
      spike.check_credentials!

      tran_id = args.fetch(:tran_id)
      req_time = spike.now
      hash = spike.sign(req_time, spike.merchant_id, tran_id)

      spike.attempt("CANCELLED — #{tran_id}") do
        spike.post_json(
          "/api/merchant-portal/merchant-access/online-transaction/pre-auth-cancellation",
          { request_time: req_time, merchant_id: spike.merchant_id, tran_id: tran_id, hash: hash }
        )
      end

      puts "Record: how long until the released funds leave the payer's hold —"
      puts "that delay is what a participant experiences when they cancel."
    end
  end
end
