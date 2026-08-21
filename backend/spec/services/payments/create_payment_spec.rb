require "rails_helper"

RSpec.describe Payments::CreatePayment do
  let(:user)         { create(:user) }
  let(:event)        { create(:event, :paid, price_cents: 2500, currency: "usd", creator: create(:user)) }
  let(:registration) { create(:registration, event: event, user: user, payment_status: "unpaid") }
  let(:callback_url) { "https://api.example.com/api/v1/webhooks/aba_payway" }

  let(:generate_qr_response) do
    {
      status: { code: "0", message: "Success", trace_id: "trace-1" },
      amount: 25.00,
      currency: "USD",
      qrString: "00020101...",
      qrImage: "data:image/png;base64,abc",
      abapay_deeplink: "abamobilebank://ababank.com?type=payway&qrcode=..."
    }
  end

  def call
    described_class.new(registration: registration, current_user: user, callback_url: callback_url).call
  end

  it "opens a pending payment and marks it created with the QR payload on success" do
    allow_any_instance_of(AbaPayway::Client).to receive(:generate_qr).and_return(generate_qr_response)

    result = call

    expect(result).to be_success
    expect(result.status).to eq(:created)
    expect(result.payment).to be_persisted
    expect(result.payment.status).to eq("pending")
    expect(result.payment.amount_cents).to eq(2500)
    expect(result.payment.qr_string).to eq("00020101...")
    expect(result.payment.abapay_deeplink).to eq(generate_qr_response[:abapay_deeplink])
  end

  it "passes the given callback_url through to the gateway" do
    expect_any_instance_of(AbaPayway::Client).to receive(:generate_qr)
      .with(hash_including(callback_url: callback_url))
      .and_return(generate_qr_response)

    call
  end

  it "returns :already_paid without creating a payment when the registration is already paid" do
    registration.update!(payment_status: "paid")

    expect {
      result = call
      expect(result.status).to eq(:already_paid)
      expect(result).not_to be_success
      expect(result.error).to eq("This registration is already paid.")
    }.not_to change(Payment, :count)
  end

  it "returns :nothing_owed without creating a payment when owed_amount_cents is 0" do
    allow(registration).to receive(:owed_amount_cents).and_return(0)

    expect {
      result = call
      expect(result.status).to eq(:nothing_owed)
      expect(result.error).to eq("This registration has nothing owed.")
    }.not_to change(Payment, :count)
  end

  # Regression coverage for change-event-plan-tickets.md's "Ticket B" bug:
  # a still-unpaid registration's charge used to be recomputed live from the
  # event's *current* price_cents, so an organizer editing the price while a
  # registrant hadn't paid yet would silently change what the next payment
  # attempt charged. amount_owed_cents now snapshots what was true at
  # registration time, so it stays fixed regardless of later price edits.
  it "charges the price snapshotted at registration time, not the event's current price" do
    registration.update!(amount_owed_cents: 2500)
    event.update!(price_cents: 9900)
    allow_any_instance_of(AbaPayway::Client).to receive(:generate_qr).and_return(generate_qr_response)

    result = call

    expect(result.payment.amount_cents).to eq(2500)
  end

  it "marks the payment declined and returns :declined when PayWay responds with a non-zero status code" do
    allow_any_instance_of(AbaPayway::Client).to receive(:generate_qr).and_return(
      { status: { code: "1", message: "Insufficient funds" } }
    )

    result = call

    expect(result.status).to eq(:declined)
    expect(result.error).to eq("Insufficient funds")
    expect(result.payment.reload.status).to eq("declined")
  end

  it "marks the payment declined and returns :gateway_error when the gateway raises" do
    allow_any_instance_of(AbaPayway::Client).to receive(:generate_qr).and_raise(AbaPayway::RequestError, "timeout")

    result = call

    expect(result.status).to eq(:gateway_error)
    expect(result.error).to eq("Could not start payment: timeout")
    expect(result.payment.reload.status).to eq("declined")
    expect(result.payment.raw_response).to eq({ "error" => "timeout" })
  end
end
