require "rails_helper"

RSpec.describe "Refunds API", type: :request do
  let(:organizer) { create(:user) }
  let(:event) { create(:event, creator: organizer, price_cents: 2500, currency: "usd") }
  let(:participant) { create(:user) }
  let(:registration) do
    create(:registration, :paid, event: event, user: participant)
  end
  let!(:payment) do
    create(:payment, :approved, registration: registration, amount_cents: 2500, currency: "usd")
  end

  let(:gateway_success_response) do
    {
      grand_total: 25.0,
      total_refunded: 25.0,
      currency: "USD",
      transaction_status: "REFUNDED",
      status: { code: "00", message: "Success!" }
    }
  end

  describe "POST /api/v1/payments/:payment_id/refunds" do
    context "as the organizer" do
      it "issues a full gateway refund, cancels the registration, and frees capacity" do
        event.update!(capacity: 1)
        allow_any_instance_of(AbaPayway::Client).to receive(:refund).and_return(gateway_success_response)

        post "/api/v1/payments/#{payment.id}/refunds", headers: auth_headers(organizer), as: :json

        expect(response).to have_http_status(:created)
        expect(json["refund"]["status"]).to eq("succeeded")
        expect(json["refund"]["amount_cents"]).to eq(2500)
        expect(json["payment"]["status"]).to eq("refunded")

        expect(payment.reload.refunded_amount_cents).to eq(2500)
        expect(registration.reload.status).to eq("cancelled")
        expect(registration.payment_status).to eq("refunded")
        expect(registration.amount_paid_cents).to eq(0)
        expect(event.reload.full?).to eq(false)
      end

      it "promotes the next waitlist entry after a full refund frees a spot" do
        event.update!(capacity: 1)
        waiting_user = create(:user)
        entry = create(:waitlist_entry, event: event, user: waiting_user)
        allow_any_instance_of(AbaPayway::Client).to receive(:refund).and_return(gateway_success_response)

        post "/api/v1/payments/#{payment.id}/refunds", headers: auth_headers(organizer), as: :json

        expect(response).to have_http_status(:created)
        expect(entry.reload.status).to eq("promoted")
        expect(waiting_user.registrations.exists?(event_id: event.id)).to eq(true)
      end

      it "issues a partial refund without cancelling the registration" do
        allow_any_instance_of(AbaPayway::Client).to receive(:refund).and_return(
          gateway_success_response.merge(total_refunded: 10.0)
        )

        post "/api/v1/payments/#{payment.id}/refunds",
          params: { refund: { amount_cents: 1000 } }, headers: auth_headers(organizer), as: :json

        expect(response).to have_http_status(:created)
        expect(payment.reload.status).to eq("partially_refunded")
        expect(payment.refunded_amount_cents).to eq(1000)
        expect(registration.reload.status).to eq("confirmed")
        expect(registration.payment_status).to eq("partially_refunded")
        expect(registration.amount_paid_cents).to eq(1500)
      end

      it "records a manual refund without calling ABA PayWay" do
        expect_any_instance_of(AbaPayway::Client).not_to receive(:refund)

        post "/api/v1/payments/#{payment.id}/refunds",
          params: { refund: { refund_method: "manual", reason: "Refunded via bank transfer" } },
          headers: auth_headers(organizer), as: :json

        expect(response).to have_http_status(:created)
        expect(json["refund"]["refund_method"]).to eq("manual")
        expect(registration.reload.status).to eq("cancelled")
      end

      it "requires a reason for a manual refund" do
        post "/api/v1/payments/#{payment.id}/refunds",
          params: { refund: { refund_method: "manual" } }, headers: auth_headers(organizer), as: :json

        expect(response).to have_http_status(:unprocessable_entity)
      end

      it "rejects a refund amount greater than what's still refundable" do
        post "/api/v1/payments/#{payment.id}/refunds",
          params: { refund: { amount_cents: 10_000 } }, headers: auth_headers(organizer), as: :json

        expect(response).to have_http_status(:unprocessable_entity)
      end

      it "rejects refunding a payment that was never approved" do
        pending_payment = create(:payment, registration: registration, status: "pending")

        post "/api/v1/payments/#{pending_payment.id}/refunds", headers: auth_headers(organizer), as: :json

        expect(response).to have_http_status(:unprocessable_entity)
      end

      it "returns 502 and still logs a failed Refund when ABA PayWay is unreachable" do
        allow_any_instance_of(AbaPayway::Client).to receive(:refund).and_raise(AbaPayway::RequestError, "timeout")

        post "/api/v1/payments/#{payment.id}/refunds", headers: auth_headers(organizer), as: :json

        expect(response).to have_http_status(:bad_gateway)
        expect(payment.reload.refunds.last.status).to eq("failed")
        expect(payment.status).to eq("approved") # unchanged — nothing succeeded
      end
    end

    context "as an admin who isn't the organizer" do
      it "is allowed" do
        admin = create(:user, admin: true)
        allow_any_instance_of(AbaPayway::Client).to receive(:refund).and_return(gateway_success_response)

        post "/api/v1/payments/#{payment.id}/refunds", headers: auth_headers(admin), as: :json

        expect(response).to have_http_status(:created)
      end
    end

    context "as neither the organizer nor an admin" do
      it "is forbidden" do
        other_user = create(:user)

        post "/api/v1/payments/#{payment.id}/refunds", headers: auth_headers(other_user), as: :json

        expect(response).to have_http_status(:forbidden)
      end
    end

    it "requires authentication" do
      post "/api/v1/payments/#{payment.id}/refunds", as: :json
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "GET /api/v1/payments/:payment_id/refunds" do
    it "lists refund history for the organizer" do
      create(:refund, payment: payment, initiated_by: organizer, amount_cents: 1000)

      get "/api/v1/payments/#{payment.id}/refunds", headers: auth_headers(organizer), as: :json

      expect(response).to have_http_status(:ok)
      expect(json["refunds"].length).to eq(1)
    end
  end
end
