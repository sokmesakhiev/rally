require "rails_helper"

RSpec.describe "Results API", type: :request do
  let(:organizer)   { create(:user) }
  let(:participant) { create(:user) }
  let(:other)       { create(:user) }

  # ── PATCH /api/v1/registrations/:id/result ───────────────────────────────────
  describe "PATCH /api/v1/registrations/:id/result" do
    let!(:event) { create(:event, creator: organizer) }
    let!(:reg)   { create(:registration, event: event, user: participant) }

    it "creates a result with the given finish time" do
      patch "/api/v1/registrations/#{reg.id}/result",
            params: { result: { finish_time_seconds: 5025 } },
            headers: auth_headers(organizer),
            as: :json

      expect(response).to have_http_status(:ok)
      expect(json["result"]["finish_time_seconds"]).to eq(5025)
      expect(reg.reload.result.finish_time_seconds).to eq(5025)
    end

    it "updates an existing result rather than creating a duplicate" do
      create(:result, registration: reg, finish_time_seconds: 6000)

      expect {
        patch "/api/v1/registrations/#{reg.id}/result",
              params: { result: { finish_time_seconds: 5025 } },
              headers: auth_headers(organizer),
              as: :json
      }.not_to change(Result, :count)

      expect(response).to have_http_status(:ok)
      expect(json["result"]["finish_time_seconds"]).to eq(5025)
    end

    it "clears a result when finish_time_seconds is null" do
      create(:result, registration: reg, finish_time_seconds: 6000)

      patch "/api/v1/registrations/#{reg.id}/result",
            params: { result: { finish_time_seconds: nil } },
            headers: auth_headers(organizer),
            as: :json

      expect(response).to have_http_status(:ok)
      expect(reg.reload.result.finish_time_seconds).to be_nil
    end

    it "returns 422 for a non-integer finish_time_seconds" do
      patch "/api/v1/registrations/#{reg.id}/result",
            params: { result: { finish_time_seconds: "not-a-number" } },
            headers: auth_headers(organizer),
            as: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "returns 403 when a non-organizer tries to set a result" do
      patch "/api/v1/registrations/#{reg.id}/result",
            params: { result: { finish_time_seconds: 5025 } },
            headers: auth_headers(other),
            as: :json

      expect(response).to have_http_status(:forbidden)
    end

    it "returns 401 without a token" do
      patch "/api/v1/registrations/#{reg.id}/result",
            params: { result: { finish_time_seconds: 5025 } },
            as: :json

      expect(response).to have_http_status(:unauthorized)
    end

    # Issue #278 — Manager may set results; Check-in and Viewer may not.
    it "allows a Manager member to set a result" do
      manager = create(:user)
      create(:event_membership, event: event, user: manager, role: "manager")

      patch "/api/v1/registrations/#{reg.id}/result",
            params: { result: { finish_time_seconds: 5025 } },
            headers: auth_headers(manager),
            as: :json

      expect(response).to have_http_status(:ok)
    end

    it "returns 403 when a Check-in member tries to set a result" do
      check_in_staff = create(:user)
      create(:event_membership, event: event, user: check_in_staff, role: "check_in")

      patch "/api/v1/registrations/#{reg.id}/result",
            params: { result: { finish_time_seconds: 5025 } },
            headers: auth_headers(check_in_staff),
            as: :json

      expect(response).to have_http_status(:forbidden)
    end
  end

  # ── POST /api/v1/events/:event_id/results/import ─────────────────────────────
  describe "POST /api/v1/events/:event_id/results/import" do
    let!(:event) { create(:event, creator: organizer) }

    def csv_upload(content, filename: "results.csv")
      Rack::Test::UploadedFile.new(
        StringIO.new(content),
        "text/csv",
        original_filename: filename
      )
    end

    it "sets finish times for matching participants and reports the count" do
      alice = create(:user, email: "alice@example.com")
      bob   = create(:user, email: "bob@example.com")
      reg_alice = create(:registration, event: event, user: alice)
      reg_bob   = create(:registration, event: event, user: bob)

      csv = <<~CSV
        email,finish_time
        alice@example.com,1:23:45
        bob@example.com,5000
      CSV

      post "/api/v1/events/#{event.id}/results/import",
           params: { file: csv_upload(csv) },
           headers: auth_headers(organizer)

      expect(response).to have_http_status(:ok)
      expect(json["updated"]).to eq(2)
      expect(json["errors"]).to eq([])
      expect(reg_alice.reload.result.finish_time_seconds).to eq(1 * 3600 + 23 * 60 + 45)
      expect(reg_bob.reload.result.finish_time_seconds).to eq(5000)
    end

    it "reports rows with an unknown email without aborting the rest" do
      alice = create(:user, email: "alice@example.com")
      reg_alice = create(:registration, event: event, user: alice)

      csv = <<~CSV
        email,finish_time
        alice@example.com,1:00:00
        nobody@example.com,1:00:00
      CSV

      post "/api/v1/events/#{event.id}/results/import",
           params: { file: csv_upload(csv) },
           headers: auth_headers(organizer)

      expect(response).to have_http_status(:ok)
      expect(json["updated"]).to eq(1)
      expect(json["errors"].size).to eq(1)
      expect(json["errors"].first["email"]).to eq("nobody@example.com")
      expect(reg_alice.reload.result.finish_time_seconds).to eq(3600)
    end

    it "reports rows with an unparseable finish_time" do
      alice = create(:user, email: "alice@example.com")
      create(:registration, event: event, user: alice)

      csv = <<~CSV
        email,finish_time
        alice@example.com,not-a-time
      CSV

      post "/api/v1/events/#{event.id}/results/import",
           params: { file: csv_upload(csv) },
           headers: auth_headers(organizer)

      expect(response).to have_http_status(:ok)
      expect(json["updated"]).to eq(0)
      expect(json["errors"].first["reason"]).to match(/invalid finish_time/)
    end

    it "does not match a participant registered for a different event" do
      alice = create(:user, email: "alice@example.com")
      other_event = create(:event, creator: organizer)
      create(:registration, event: other_event, user: alice)

      csv = <<~CSV
        email,finish_time
        alice@example.com,1:00:00
      CSV

      post "/api/v1/events/#{event.id}/results/import",
           params: { file: csv_upload(csv) },
           headers: auth_headers(organizer)

      expect(json["updated"]).to eq(0)
      expect(json["errors"].first["reason"]).to match(/no registration found/)
    end

    it "returns 400 when no file is attached" do
      post "/api/v1/events/#{event.id}/results/import", headers: auth_headers(organizer)

      expect(response).to have_http_status(:bad_request)
    end

    it "returns 404 when a non-organizer imports for someone else's event" do
      post "/api/v1/events/#{event.id}/results/import",
           params: { file: csv_upload("email,finish_time\n") },
           headers: auth_headers(other)

      expect(response).to have_http_status(:not_found)
    end

    it "returns 401 without a token" do
      post "/api/v1/events/#{event.id}/results/import",
           params: { file: csv_upload("email,finish_time\n") }

      expect(response).to have_http_status(:unauthorized)
    end
  end

  # ── GET /api/v1/events/:event_id/results (public leaderboard) ────────────────
  describe "GET /api/v1/events/:event_id/results" do
    let!(:event) { create(:event, creator: organizer) }

    it "requires no authentication" do
      reg = create(:registration, event: event, user: participant)
      create(:result, registration: reg, finish_time_seconds: 600)

      get "/api/v1/events/#{event.id}/results"

      expect(response).to have_http_status(:ok)
      expect(json["groups"].first["results"].first["registration_id"]).to eq(reg.id)
    end

    it "returns one empty group when the event has no event types and nothing recorded yet" do
      create(:registration, event: event)

      get "/api/v1/events/#{event.id}/results"

      expect(response).to have_http_status(:ok)
      expect(json["groups"]).to eq([ { "event_type_id" => nil, "event_type_name" => nil, "results" => [] } ])
    end

    it "returns 404 for a non-existent event" do
      get "/api/v1/events/00000000-0000-0000-0000-000000000000/results"

      expect(response).to have_http_status(:not_found)
    end
  end
end
