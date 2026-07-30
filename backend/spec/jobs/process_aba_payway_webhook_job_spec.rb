require "rails_helper"

RSpec.describe ProcessAbaPaywayWebhookJob do
  let(:registration) { create(:registration, payment_status: "unpaid") }
  let(:payment)       { create(:payment, registration: registration, status: "pending", amount_cents: 2500) }

  it "marks the payment approved and the registration paid when ABA confirms APPROVED" do
    check_response = {
      status: { code: "00", message: "Success!", tran_id: payment.tran_id },
      data: { payment_status_code: 0, payment_status: "APPROVED", payment_amount: 25.0, payment_currency: "USD" }
    }
    allow_any_instance_of(AbaPayway::Client).to receive(:check_transaction).and_return(check_response)

    expect {
      described_class.perform_now(payment)
    }.not_to change { ActionMailer::Base.deliveries.count } # deliver_later — enqueued, not delivered inline

    expect(payment.reload.status).to eq("approved")
    expect(payment.paid_at).to be_present
    expect(registration.reload.payment_status).to eq("paid")
  end

  it "does nothing when the payable is no longer pending (already processed / duplicate delivery)" do
    payment.update!(status: "approved", paid_at: Time.current)

    expect(AbaPayway::Client).not_to receive(:for_event)

    described_class.perform_now(payment)
  end

  it "does not trust a payload claiming APPROVED without a matching Check Transaction result" do
    check_response = {
      status: { code: "00", message: "Success!", tran_id: payment.tran_id },
      data: { payment_status_code: 2, payment_status: "PENDING", payment_amount: 0, payment_currency: "" }
    }
    allow_any_instance_of(AbaPayway::Client).to receive(:check_transaction).and_return(check_response)

    described_class.perform_now(payment)

    expect(payment.reload.status).to eq("pending")
  end

  it "logs and does not raise when the ABA lookup fails" do
    allow_any_instance_of(AbaPayway::Client).to receive(:check_transaction).and_raise(AbaPayway::RequestError, "down")

    expect { described_class.perform_now(payment) }.not_to raise_error
    expect(payment.reload.status).to eq("pending")
  end

  it "marks an EventPlanPayment paid via mark_paid! when ABA confirms APPROVED" do
    event = create(:event, :draft)
    plan_payment = event.event_plan_payments.create!(
      user: event.creator,
      plan: "small",
      tran_id: "plntest123",
      amount_cents: 10_000,
      currency: "usd",
      status: "pending",
      expires_at: 15.minutes.from_now
    )

    check_response = {
      status: { code: "00", message: "Success!", tran_id: plan_payment.tran_id },
      data: { payment_status_code: 0, payment_status: "APPROVED", payment_amount: 100.0, payment_currency: "USD" }
    }
    allow_any_instance_of(AbaPayway::Client).to receive(:check_transaction).and_return(check_response)

    described_class.perform_now(plan_payment)

    expect(plan_payment.reload.status).to eq("paid")
    expect(event.reload.is_published).to be(true)
    expect(event.plan).to eq("small")
  end
end
