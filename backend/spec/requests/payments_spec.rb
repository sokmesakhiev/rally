require "rails_helper"

RSpec.describe "Payments API", type: :request do
  let(:user) { create(:user, email: "payer@example.com") }
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

    # Guest checkout (see Registrations::GuestCheckout) never issues a
    # session, so an anonymous request has to be able to pay too — a
    # matching email/phone stands in for the login, same trust level
    # GuestCheckout itself uses to attach the registration in the first
    # place.
    it "allows an anonymous request when the email matches the registrant's account" do
      allow_any_instance_of(AbaPayway::Client).to receive(:generate_qr).and_return(generate_qr_response)

      post "/api/v1/registrations/#{registration.id}/payments",
           params: { email: user.email }, as: :json

      expect(response).to have_http_status(:created)
    end

    it "allows an anonymous request when the phone matches the registrant's account" do
      user.profile.update!(phone: "012345678")
      allow_any_instance_of(AbaPayway::Client).to receive(:generate_qr).and_return(generate_qr_response)

      post "/api/v1/registrations/#{registration.id}/payments",
           params: { phone: "012345678" }, as: :json

      expect(response).to have_http_status(:created)
    end

    it "returns 404 for an anonymous request with no matching contact info" do
      post "/api/v1/registrations/#{registration.id}/payments",
           params: { email: "someone-else@example.com" }, as: :json

      expect(response).to have_http_status(:not_found)
    end

    it "returns 404 for an anonymous request with no contact info at all" do
      post "/api/v1/registrations/#{registration.id}/payments", as: :json
      expect(response).to have_http_status(:not_found)
    end

    it "returns 404 when signed in as a different user, even with the right registration id" do
      other = create(:user)

      post "/api/v1/registrations/#{registration.id}/payments", headers: auth_headers(other), as: :json

      expect(response).to have_http_status(:not_found)
    end

    it "rejects when already paid" do
      registration.update!(payment_status: "paid")

      post "/api/v1/registrations/#{registration.id}/payments", headers: auth_headers(user), as: :json

      expect(response).to have_http_status(:unprocessable_content)
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

    it "allows an anonymous poll when the email matches the registrant's account" do
      payment = create(:payment, registration: registration, status: "approved")

      # No `as: :json` here deliberately — combined with `params:` on a GET,
      # Rails' JSON test encoder JSON-encodes params into the request body
      # rather than the query string, which this endpoint (like any GET)
      # doesn't read from. A plain query string works, and the controller
      # already forces JSON responses regardless of the request's format
      # (see ApplicationController#set_default_format).
      get "/api/v1/payments/#{payment.id}", params: { email: user.email }

      expect(response).to have_http_status(:ok)
    end

    it "returns 404 for an anonymous poll with no matching contact info" do
      payment = create(:payment, registration: registration)

      get "/api/v1/payments/#{payment.id}", as: :json

      expect(response).to have_http_status(:not_found)
    end
  end
end
