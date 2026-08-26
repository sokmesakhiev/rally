require "rails_helper"

RSpec.describe "Waitlist Entries API", type: :request do
  let(:organizer)   { create(:user) }
  let(:participant) { create(:user) }
  let(:other)       { create(:user) }

  # ── POST /api/v1/events/:event_id/waitlist_entries ──────────────────────────
  describe "POST /api/v1/events/:event_id/waitlist_entries" do
    it "joins the waitlist when the event is full" do
      event = create(:event, :full, creator: organizer)

      post "/api/v1/events/#{event.id}/waitlist_entries",
           headers: auth_headers(participant),
           as: :json

      expect(response).to have_http_status(:created)
      expect(json["waitlist_entry"]["event_id"]).to eq(event.id)
      expect(json["waitlist_entry"]["user_id"]).to eq(participant.id)
      expect(json["waitlist_entry"]["status"]).to eq("waiting")
    end

    it "returns 422 with a clean message and code when the event isn't actually full" do
      event = create(:event, capacity: 10, creator: organizer)

      post "/api/v1/events/#{event.id}/waitlist_entries",
           headers: auth_headers(participant),
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json["code"]).to eq("not_full")
    end

    it "returns 422 with a code when already registered for the event" do
      # capacity: 1, filled by the participant's own registration — so it's
      # both "full" and "you're already in it", same as the :full trait
      # would give us, but without a second registration racing for the
      # same one spot (which is what made the :full trait blow up here).
      event = create(:event, capacity: 1, creator: organizer)
      create(:registration, event: event, user: participant)

      post "/api/v1/events/#{event.id}/waitlist_entries",
           headers: auth_headers(participant),
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json["code"]).to eq("already_registered")
    end

    it "returns 422 when already on the waitlist" do
      event = create(:event, :full, creator: organizer)
      create(:waitlist_entry, event: event, user: participant)

      post "/api/v1/events/#{event.id}/waitlist_entries",
           headers: auth_headers(participant),
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "accepts specific event_type_ids" do
      event = create(:event, capacity: 10, creator: organizer)
      full_type = event.event_types.create!(name: "5K", capacity: 1, position: 0)
      create(:registration, event: event).registration_event_types.create!(event_type: full_type)

      post "/api/v1/events/#{event.id}/waitlist_entries",
           params: { event_type_ids: [ full_type.id ] },
           headers: auth_headers(participant),
           as: :json

      expect(response).to have_http_status(:created)
      expect(json["waitlist_entry"]["event_type_ids"]).to eq([ full_type.id ])
    end

    it "returns 401 without a token" do
      event = create(:event, :full, creator: organizer)
      post "/api/v1/events/#{event.id}/waitlist_entries", as: :json
      expect(response).to have_http_status(:unauthorized)
    end
  end

  # ── GET /api/v1/waitlist_entries (mine) ──────────────────────────────────────
  describe "GET /api/v1/waitlist_entries" do
    it "returns only the current user's active waitlist entries" do
      event = create(:event, :full, creator: organizer)
      mine    = create(:waitlist_entry, event: event, user: participant)
      not_mine = create(:waitlist_entry, event: event, user: other)

      get "/api/v1/waitlist_entries", headers: auth_headers(participant), as: :json

      ids = json["waitlist_entries"].map { |e| e["id"] }
      expect(ids).to include(mine.id)
      expect(ids).not_to include(not_mine.id)
    end

    it "excludes entries that have already been promoted or cancelled" do
      event = create(:event, :full, creator: organizer)
      create(:waitlist_entry, :promoted, event: event, user: participant)
      create(:waitlist_entry, :cancelled, event: event, user: participant)

      get "/api/v1/waitlist_entries", headers: auth_headers(participant), as: :json

      expect(json["waitlist_entries"]).to eq([])
    end
  end

  # ── GET /api/v1/events/:event_id/waitlist_entries (organizer view) ──────────
  describe "GET /api/v1/events/:event_id/waitlist_entries" do
    it "returns the waitlist in join order for the event organizer" do
      event = create(:event, :full, creator: organizer)
      first  = create(:waitlist_entry, event: event, user: participant, created_at: 2.hours.ago)
      second = create(:waitlist_entry, event: event, user: other, created_at: 1.hour.ago)

      get "/api/v1/events/#{event.id}/waitlist_entries", headers: auth_headers(organizer), as: :json

      expect(response).to have_http_status(:ok)
      ids = json["waitlist_entries"].map { |e| e["id"] }
      expect(ids).to eq([ first.id, second.id ])
      expect(json["waitlist_entries"].first["position"]).to eq(1)
    end

    it "returns 403 for a non-organizer" do
      event = create(:event, :full, creator: organizer)

      get "/api/v1/events/#{event.id}/waitlist_entries", headers: auth_headers(other), as: :json

      expect(response).to have_http_status(:forbidden)
    end

    # Issue #278 — Viewer gets read-only access to the waitlist; Check-in
    # does not (it's not part of their job at the door).
    it "allows a Viewer member to view the waitlist" do
      event = create(:event, :full, creator: organizer)
      viewer = create(:user)
      create(:event_membership, event: event, user: viewer, role: "viewer")

      get "/api/v1/events/#{event.id}/waitlist_entries", headers: auth_headers(viewer), as: :json

      expect(response).to have_http_status(:ok)
    end

    it "returns 403 for a Check-in member" do
      event = create(:event, :full, creator: organizer)
      check_in_staff = create(:user)
      create(:event_membership, event: event, user: check_in_staff, role: "check_in")

      get "/api/v1/events/#{event.id}/waitlist_entries", headers: auth_headers(check_in_staff), as: :json

      expect(response).to have_http_status(:forbidden)
    end
  end

  # ── DELETE /api/v1/waitlist_entries/:id ──────────────────────────────────────
  describe "DELETE /api/v1/waitlist_entries/:id" do
    it "lets a participant leave their own waitlist spot" do
      event = create(:event, :full, creator: organizer)
      entry = create(:waitlist_entry, event: event, user: participant)

      delete "/api/v1/waitlist_entries/#{entry.id}", headers: auth_headers(participant), as: :json

      expect(response).to have_http_status(:ok)
      expect(entry.reload.status).to eq("cancelled")
    end

    it "returns 404 when trying to remove someone else's entry" do
      event = create(:event, :full, creator: organizer)
      entry = create(:waitlist_entry, event: event, user: participant)

      delete "/api/v1/waitlist_entries/#{entry.id}", headers: auth_headers(other), as: :json

      expect(response).to have_http_status(:not_found)
    end
  end
end
