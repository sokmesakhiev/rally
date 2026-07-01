require "rails_helper"

RSpec.describe "Registrations API", type: :request do
  let(:organizer)    { create(:user) }
  let(:participant)  { create(:user) }
  let(:other)        { create(:user) }

  # ── GET /api/v1/registrations ────────────────────────────────────────────────
  describe "GET /api/v1/registrations" do
    let!(:my_reg)    { create(:registration, user: participant) }
    let!(:other_reg) { create(:registration, user: other) }

    it "returns only the current user's registrations with event data" do
      get "/api/v1/registrations", headers: auth_headers(participant), as: :json

      expect(response).to have_http_status(:ok)
      ids = json["registrations"].map { |r| r["id"] }
      expect(ids).to include(my_reg.id)
      expect(ids).not_to include(other_reg.id)
    end

    it "includes nested event data" do
      get "/api/v1/registrations", headers: auth_headers(participant), as: :json

      reg_json = json["registrations"].find { |r| r["id"] == my_reg.id }
      expect(reg_json["event"]).to be_present
      expect(reg_json["event"]["id"]).to eq(my_reg.event_id)
    end

    it "returns 401 without a token" do
      get "/api/v1/registrations", as: :json
      expect(response).to have_http_status(:unauthorized)
    end
  end

  # ── POST /api/v1/events/:event_id/registrations ──────────────────────────────
  describe "POST /api/v1/events/:event_id/registrations" do
    let!(:event) { create(:event, creator: organizer) }

    it "registers the current user for the event" do
      post "/api/v1/events/#{event.id}/registrations",
           headers: auth_headers(participant),
           as: :json

      expect(response).to have_http_status(:created)
      expect(json["registration"]["event_id"]).to eq(event.id)
      expect(json["registration"]["user_id"]).to eq(participant.id)
    end

    it "sets payment_status to paid for a free event" do
      post "/api/v1/events/#{event.id}/registrations",
           headers: auth_headers(participant),
           as: :json

      expect(json["registration"]["payment_status"]).to eq("paid")
    end

    it "sets payment_status to unpaid for a paid event" do
      paid_event = create(:event, :paid, creator: organizer)
      post "/api/v1/events/#{paid_event.id}/registrations",
           headers: auth_headers(participant),
           as: :json

      expect(json["registration"]["payment_status"]).to eq("unpaid")
    end

    it "prevents double-registration" do
      create(:registration, event: event, user: participant)
      post "/api/v1/events/#{event.id}/registrations",
           headers: auth_headers(participant),
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "returns 422 when the event is full" do
      full_event = create(:event, capacity: 1, creator: organizer)
      create(:registration, event: full_event)

      post "/api/v1/events/#{full_event.id}/registrations",
           headers: auth_headers(participant),
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "returns 401 without a token" do
      post "/api/v1/events/#{event.id}/registrations", as: :json
      expect(response).to have_http_status(:unauthorized)
    end
  end

  # ── GET /api/v1/events/:event_id/registrations (organizer view) ──────────────
  describe "GET /api/v1/events/:event_id/registrations" do
    let!(:event) { create(:event, creator: organizer) }
    let!(:reg)   { create(:registration, event: event) }

    it "returns participant list for the event organizer" do
      get "/api/v1/events/#{event.id}/registrations",
          headers: auth_headers(organizer),
          as: :json

      expect(response).to have_http_status(:ok)
      expect(json["registrations"].map { |r| r["id"] }).to include(reg.id)
    end

    it "returns 404 when a non-organizer tries to access the list" do
      get "/api/v1/events/#{event.id}/registrations",
          headers: auth_headers(other),
          as: :json

      expect(response).to have_http_status(:not_found)
    end
  end

  # ── PATCH /api/v1/registrations/:id ─────────────────────────────────────────
  describe "PATCH /api/v1/registrations/:id" do
    let!(:event) { create(:event, :paid, creator: organizer) }
    let!(:reg)   { create(:registration, event: event) }

    it "allows the organizer to mark a registration as paid" do
      patch "/api/v1/registrations/#{reg.id}",
            params: { registration: { payment_status: "paid", amount_paid_cents: 2500 } },
            headers: auth_headers(organizer),
            as: :json

      expect(response).to have_http_status(:ok)
      expect(json["registration"]["payment_status"]).to eq("paid")
      expect(json["registration"]["amount_paid_cents"]).to eq(2500)
    end

    it "returns 403 when a non-organizer tries to update" do
      patch "/api/v1/registrations/#{reg.id}",
            params: { registration: { payment_status: "paid", amount_paid_cents: 2500 } },
            headers: auth_headers(other),
            as: :json

      expect(response).to have_http_status(:forbidden)
    end
  end

  # ── DELETE /api/v1/registrations/:id ────────────────────────────────────────
  describe "DELETE /api/v1/registrations/:id" do
    let!(:event) { create(:event, creator: organizer) }
    let!(:reg)   { create(:registration, event: event) }

    it "allows the organizer to remove a participant" do
      delete "/api/v1/registrations/#{reg.id}",
             headers: auth_headers(organizer),
             as: :json

      expect(response).to have_http_status(:ok)
      expect(Registration.find_by(id: reg.id)).to be_nil
    end

    it "returns 403 when a non-organizer tries to remove" do
      delete "/api/v1/registrations/#{reg.id}",
             headers: auth_headers(other),
             as: :json

      expect(response).to have_http_status(:forbidden)
    end
  end
end
