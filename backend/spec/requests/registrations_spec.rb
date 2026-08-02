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

    it "omits certificate_url when no certificate has been generated yet" do
      get "/api/v1/registrations", headers: auth_headers(participant), as: :json

      reg_json = json["registrations"].find { |r| r["id"] == my_reg.id }
      expect(reg_json).not_to have_key("certificate_url")
    end

    it "includes certificate_url once a certificate has been generated" do
      create(:certificate, :with_file, registration: my_reg)

      get "/api/v1/registrations", headers: auth_headers(participant), as: :json

      reg_json = json["registrations"].find { |r| r["id"] == my_reg.id }
      expect(reg_json["certificate_url"]).to be_present
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

    it "returns 422 with a clean message and code when the event is full" do
      full_event = create(:event, capacity: 1, creator: organizer)
      create(:registration, event: full_event)

      post "/api/v1/events/#{full_event.id}/registrations",
           headers: auth_headers(participant),
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json["error"]).to eq("This event is full")
      expect(json["code"]).to eq("full")
    end

    it "returns 422 with a clean message and code when the selected event type is full" do
      typed_event = create(:event, creator: organizer)
      full_type = typed_event.event_types.create!(name: "5K", capacity: 1, position: 0)
      create(:registration, event: typed_event).registration_event_types.create!(event_type: full_type)

      post "/api/v1/events/#{typed_event.id}/registrations",
           params: { event_type_ids: [ full_type.id ] },
           headers: auth_headers(participant),
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json["error"]).to eq("5K is full")
      expect(json["code"]).to eq("full")
    end

    it "does not set a code for non-capacity failures" do
      post "/api/v1/events/#{event.id}/registrations",
           headers: auth_headers(participant),
           as: :json
      post "/api/v1/events/#{event.id}/registrations",
           headers: auth_headers(participant),
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json["error"]).to eq("Already registered")
      expect(json["code"]).to be_nil
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

    it "includes certificate_url in the organizer view once generated" do
      create(:certificate, :with_file, registration: reg)

      get "/api/v1/events/#{event.id}/registrations",
          headers: auth_headers(organizer),
          as: :json

      reg_json = json["registrations"].find { |r| r["id"] == reg.id }
      expect(reg_json["certificate_url"]).to be_present
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

    it "returns 422 for an unknown payment_status (schema)" do
      patch "/api/v1/registrations/#{reg.id}",
            params: { registration: { payment_status: "bogus" } },
            headers: auth_headers(organizer),
            as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json["error"]).to be_present
      expect(reg.reload.payment_status).not_to eq("bogus")
    end

    # No "missing registration wrapper key" case here: Rails' ParamsWrapper
    # (active by default for JSON requests, even with config.api_only = true)
    # auto-nests any flat top-level params matching a Registration attribute
    # name (payment_status, amount_paid_cents, ...) under a "registration"
    # key before the schema ever runs, so that key is guaranteed present on
    # every real JSON request here — there's no request shape that can
    # trigger required(:registration) failing in practice.
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

    it "promotes the longest-waiting waitlist entry when removing a participant frees a spot" do
      full_event = create(:event, :full, creator: organizer)
      full_reg   = full_event.registrations.first
      waiter     = create(:waitlist_entry, event: full_event)

      delete "/api/v1/registrations/#{full_reg.id}",
             headers: auth_headers(organizer),
             as: :json

      expect(response).to have_http_status(:ok)
      expect(waiter.reload.status).to eq("promoted")
      expect(Registration.exists?(event_id: full_event.id, user_id: waiter.user_id)).to be(true)
    end
  end

  # ── POST /api/v1/registrations/:id/check_in ─────────────────────────────────
  describe "POST /api/v1/registrations/:id/check_in" do
    let!(:event) { create(:event, creator: organizer) }
    let!(:reg)   { create(:registration, event: event) }

    it "marks the registration checked in" do
      post "/api/v1/registrations/#{reg.id}/check_in",
           headers: auth_headers(organizer),
           as: :json

      expect(response).to have_http_status(:ok)
      expect(json["already_checked_in"]).to be(false)
      expect(json["registration"]["checked_in_at"]).to be_present
      expect(reg.reload.checked_in_at).to be_present
    end

    it "is idempotent — re-scanning reports already_checked_in without moving the timestamp" do
      post "/api/v1/registrations/#{reg.id}/check_in", headers: auth_headers(organizer), as: :json
      first_timestamp = reg.reload.checked_in_at

      post "/api/v1/registrations/#{reg.id}/check_in", headers: auth_headers(organizer), as: :json

      expect(response).to have_http_status(:ok)
      expect(json["already_checked_in"]).to be(true)
      expect(reg.reload.checked_in_at).to eq(first_timestamp)
    end

    it "returns 403 when a non-organizer tries to check someone in" do
      post "/api/v1/registrations/#{reg.id}/check_in",
           headers: auth_headers(other),
           as: :json

      expect(response).to have_http_status(:forbidden)
    end

    it "returns 401 without a token" do
      post "/api/v1/registrations/#{reg.id}/check_in", as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 404 for an unknown registration" do
      post "/api/v1/registrations/00000000-0000-0000-0000-000000000000/check_in",
           headers: auth_headers(organizer),
           as: :json

      expect(response).to have_http_status(:not_found)
    end
  end

  # ── DELETE /api/v1/registrations/:id/check_in ───────────────────────────────
  describe "DELETE /api/v1/registrations/:id/check_in" do
    let!(:event) { create(:event, creator: organizer) }
    let!(:reg)   { create(:registration, event: event, checked_in_at: Time.current) }

    it "clears the check-in" do
      delete "/api/v1/registrations/#{reg.id}/check_in",
             headers: auth_headers(organizer),
             as: :json

      expect(response).to have_http_status(:ok)
      expect(json["registration"]["checked_in_at"]).to be_nil
      expect(reg.reload.checked_in_at).to be_nil
    end

    it "returns 403 when a non-organizer tries to undo a check-in" do
      delete "/api/v1/registrations/#{reg.id}/check_in",
             headers: auth_headers(other),
             as: :json

      expect(response).to have_http_status(:forbidden)
    end
  end

  # ── finish_time_seconds exposure ─────────────────────────────────────────────
  describe "finish_time_seconds on registration_json" do
    let!(:event) { create(:event, creator: organizer) }
    let!(:reg)   { create(:registration, event: event, user: participant) }

    it "is omitted when no result has been recorded" do
      get "/api/v1/registrations", headers: auth_headers(participant), as: :json

      reg_json = json["registrations"].find { |r| r["id"] == reg.id }
      expect(reg_json).not_to have_key("finish_time_seconds")
    end

    it "is present once a result has been recorded" do
      create(:result, registration: reg, finish_time_seconds: 5025)

      get "/api/v1/registrations", headers: auth_headers(participant), as: :json

      reg_json = json["registrations"].find { |r| r["id"] == reg.id }
      expect(reg_json["finish_time_seconds"]).to eq(5025)
    end

    it "is present in the organizer's view too" do
      create(:result, registration: reg, finish_time_seconds: 5025)

      get "/api/v1/events/#{event.id}/registrations", headers: auth_headers(organizer), as: :json

      reg_json = json["registrations"].find { |r| r["id"] == reg.id }
      expect(reg_json["finish_time_seconds"]).to eq(5025)
    end
  end
end
