require "rails_helper"

RSpec.describe "ABA PayWay Webhook", type: :request do
  let(:registration) { create(:registration, payment_status: "unpaid") }
  let(:payment) { create(:payment, registration: registration, status: "pending", amount_cents: 2500) }

  it "acks immediately and enqueues a job instead of calling ABA inline" do
    expect {
      post "/api/v1/webhooks/aba_payway", params: { merchant_ref: payment.tran_id }, as: :json
    }.to have_enqueued_job(ProcessAbaPaywayWebhookJob).with(payment)

    expect(response).to have_http_status(:ok)
    # Nothing should have changed yet — the actual verification happens in
    # the job, not in the request itself.
    expect(payment.reload.status).to eq("pending")
  end

  it "marks the payment approved once the enqueued job runs and ABA confirms APPROVED" do
    check_response = {
      status: { code: "00", message: "Success!", tran_id: payment.tran_id },
      data: { payment_status_code: 0, payment_status: "APPROVED", payment_amount: 25.0, payment_currency: "USD" }
    }
    allow_any_instance_of(AbaPayway::Client).to receive(:check_transaction).and_return(check_response)

    perform_enqueued_jobs do
      post "/api/v1/webhooks/aba_payway", params: { merchant_ref: payment.tran_id }, as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(payment.reload.status).to eq("approved")
    expect(registration.reload.payment_status).to eq("paid")
  end

  it "ignores an unknown tran_id without erroring or enqueueing a job" do
    expect {
      post "/api/v1/webhooks/aba_payway", params: { merchant_ref: "does-not-exist" }, as: :json
    }.not_to have_enqueued_job(ProcessAbaPaywayWebhookJob)

    expect(response).to have_http_status(:ok)
  end

  it "does not trust a payload claiming APPROVED without a matching Check Transaction result" do
    check_response = {
      status: { code: "00", message: "Success!", tran_id: payment.tran_id },
      data: { payment_status_code: 2, payment_status: "PENDING", payment_amount: 0, payment_currency: "" }
    }
    allow_any_instance_of(AbaPayway::Client).to receive(:check_transaction).and_return(check_response)

    perform_enqueued_jobs do
      post "/api/v1/webhooks/aba_payway",
           params: { merchant_ref: payment.tran_id, payment_status: "APPROVED" },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(payment.reload.status).to eq("pending")
  end

  it "responds 200 even if the job's ABA lookup fails" do
    allow_any_instance_of(AbaPayway::Client).to receive(:check_transaction).and_raise(AbaPayway::RequestError, "down")

    perform_enqueued_jobs do
      post "/api/v1/webhooks/aba_payway", params: { merchant_ref: payment.tran_id }, as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(payment.reload.status).to eq("pending")
  end
end
