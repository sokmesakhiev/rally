require "rails_helper"

RSpec.describe "Payments API", type: :request do
  let(:user) { create(:user) }
  let(:event) { create(:event, :paid, price_cents: 2500, currency: "usd") }
  let(:registration) { create(:registration, event: event, user: user, payment_status: "unpaid") }

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

  describe "POST /api/v1/registrations/:registration_id/payments" do
    it "creates a pending payment and returns the QR payload" do
      allow_any_instance_of(AbaPayway::Client).to receive(:generate_qr).and_return(generate_qr_response)

      post "/api/v1/registrations/#{registration.id}/payments", headers: auth_headers(user), as: :json

      expect(response).to have_http_status(:created)
      expect(json["payment"]["status"]).to eq("pending")
      expect(json["payment"]["qr_string"]).to eq("00020101...")
      expect(json["payment"]["amount_cents"]).to eq(2500)
    end

    it "requires authentication" do
      post "/api/v1/registrations/#{registration.id}/payments", as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    it "rejects when already paid" do
      registration.update!(payment_status: "paid")

      post "/api/v1/registrations/#{registration.id}/payments", headers: auth_headers(user), as: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "returns 502 when ABA PayWay is unreachable" do
      allow_any_instance_of(AbaPayway::Client).to receive(:generate_qr).and_raise(AbaPayway::RequestError, "timeout")

      post "/api/v1/registrations/#{registration.id}/payments", headers: auth_headers(user), as: :json

      expect(response).to have_http_status(:bad_gateway)
    end
  end

  describe "GET /api/v1/payments/:id" do
    it "returns the payment status, refreshing from ABA when stale" do
      payment = create(:payment, registration: registration, amount_cents: 2500,
                        status: "pending", created_at: 1.minute.ago, updated_at: 1.minute.ago)

      check_response = {
        status: { code: "00", message: "Success!", tran_id: payment.tran_id },
        data: { payment_status_code: 0, payment_status: "APPROVED", payment_amount: 25.0, payment_currency: "USD" }
      }
      allow_any_instance_of(AbaPayway::Client).to receive(:check_transaction).and_return(check_response)

      get "/api/v1/payments/#{payment.id}", headers: auth_headers(user), as: :json

      expect(response).to have_http_status(:ok)
      expect(json["payment"]["status"]).to eq("approved")
      expect(registration.reload.payment_status).to eq("paid")
    end

    it "returns 404 for another user's payment" do
      other = create(:user)
      payment = create(:payment, registration: registration)

      get "/api/v1/payments/#{payment.id}", headers: auth_headers(other), as: :json

      expect(response).to have_http_status(:not_found)
    end
  end
end
