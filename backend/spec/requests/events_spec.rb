require "rails_helper"

RSpec.describe "Events API", type: :request do
  let(:user)  { create(:user) }
  let(:other) { create(:user) }

  # ── GET /api/v1/events ───────────────────────────────────────────────────────
  describe "GET /api/v1/events" do
    let!(:published_upcoming) { create(:event, is_published: true,  start_at: 1.week.from_now) }
    let!(:draft)              { create(:event, :draft,              start_at: 1.week.from_now) }
    let!(:past)               { create(:event, :past) }

    it "returns only published upcoming events" do
      get "/api/v1/events", as: :json

      expect(response).to have_http_status(:ok)
      ids = json["events"].map { |e| e["id"] }
      expect(ids).to include(published_upcoming.id)
      expect(ids).not_to include(draft.id, past.id)
    end

    it "does not require authentication" do
      get "/api/v1/events", as: :json
      expect(response).to have_http_status(:ok)
    end

    it "reports the correct spots_remaining per event type without an N+1 query per type" do
      event = create(:event, is_published: true, start_at: 1.week.from_now)
      type = event.event_types.create!(name: "5K", capacity: 3, position: 0)
      create(:registration, event: event).registration_event_types.create!(event_type: type)

      query_count = 0
      counter = ->(*, payload) { query_count += 1 unless payload[:sql].match?(/\A(BEGIN|COMMIT|SAVEPOINT|RELEASE)/) }

      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
        get "/api/v1/events", as: :json
      end

      expect(response).to have_http_status(:ok)
      returned = json["events"].find { |e| e["id"] == event.id }
      returned_type = returned["event_types"].find { |t| t["id"] == type.id }
      expect(returned_type["spots_remaining"]).to eq(2)

      # One query for events, one for event_types, one for
      # registration_event_types (all via .includes) — not one additional
      # COUNT per event type. Generous upper bound so this doesn't become
      # flaky against unrelated query count changes elsewhere.
      expect(query_count).to be <= 5
    end
  end

  # ── GET /api/v1/events/my ────────────────────────────────────────────────────
  describe "GET /api/v1/events/my" do
    let!(:my_event)    { create(:event, creator: user) }
    let!(:other_event) { create(:event, creator: other) }

    it "returns only the current user's events" do
      get "/api/v1/events/my", headers: auth_headers(user), as: :json

      ids = json["events"].map { |e| e["id"] }
      expect(ids).to include(my_event.id)
      expect(ids).not_to include(other_event.id)
    end

    it "requires authentication" do
      get "/api/v1/events/my", as: :json
      expect(response).to have_http_status(:unauthorized)
    end
  end

  # ── GET /api/v1/events/:id ───────────────────────────────────────────────────
  describe "GET /api/v1/events/:id" do
    let!(:event) { create(:event) }

    it "returns the event" do
      get "/api/v1/events/#{event.id}", as: :json

      expect(response).to have_http_status(:ok)
      expect(json["event"]["id"]).to eq(event.id)
      expect(json["event"]["title"]).to eq(event.title)
    end

    it "returns 404 for an unknown id" do
      get "/api/v1/events/#{SecureRandom.uuid}", as: :json
      expect(response).to have_http_status(:not_found)
    end
  end

  # ── POST /api/v1/events ──────────────────────────────────────────────────────
  describe "POST /api/v1/events" do
    let(:valid_params) do
      {
        event: {
          title: "Sunrise 10K",
          category: "running",
          start_at: 1.week.from_now.iso8601,
          price_cents: 0
        }
      }
    end

    it "creates an event for the authenticated user" do
      post "/api/v1/events", params: valid_params, headers: auth_headers(user), as: :json

      expect(response).to have_http_status(:created)
      expect(json["event"]["title"]).to eq("Sunrise 10K")
      expect(json["event"]["creator_id"]).to eq(user.id)
    end

    it "returns 422 when title is missing" do
      post "/api/v1/events",
           params: { event: valid_params[:event].except(:title) },
           headers: auth_headers(user),
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "returns 401 without a token" do
      post "/api/v1/events", params: valid_params, as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    it "creates event types via event_types_attributes" do
      params = valid_params.deep_merge(
        event: {
          event_types_attributes: [
            { name: "5K", capacity: 100, price_cents: 1000, position: 0 },
            { name: "10K", position: 1 }
          ]
        }
      )

      post "/api/v1/events", params: params, headers: auth_headers(user), as: :json

      expect(response).to have_http_status(:created)
      expect(json["event"]["event_types"].map { |t| t["name"] }).to contain_exactly("5K", "10K")
    end

    it "ignores a client-supplied capacity — only the publish flow may set it" do
      params = valid_params.deep_merge(event: { capacity: 999_999 })

      post "/api/v1/events", params: params, headers: auth_headers(user), as: :json

      expect(response).to have_http_status(:created)
      expect(json["event"]["capacity"]).to be_nil
    end

    it "ignores a client-supplied is_published — only the paid publish flow may set it" do
      params = valid_params.deep_merge(event: { is_published: true })

      post "/api/v1/events", params: params, headers: auth_headers(user), as: :json

      expect(response).to have_http_status(:created)
      expect(json["event"]["is_published"]).to be(false)
    end

    it "creates an event without a survey, location pin, or route link" do
      post "/api/v1/events", params: valid_params, headers: auth_headers(user), as: :json

      expect(response).to have_http_status(:created)
      expect(json["event"]["latitude"]).to be_nil
      expect(json["event"]["route_map_url"]).to be_nil
    end

    it "returns 422 (not 200) with a usable error message for an invalid schema shape" do
      post "/api/v1/events",
           params: { event: valid_params[:event].merge(latitude: 11.5) },
           headers: auth_headers(user),
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json["error"]).to be_present
    end
  end

  # ── PATCH /api/v1/events/:id ─────────────────────────────────────────────────
  describe "PATCH /api/v1/events/:id" do
    let!(:event) { create(:event, creator: user, title: "Old Title") }

    it "updates the event" do
      patch "/api/v1/events/#{event.id}",
            params: { event: { title: "New Title" } },
            headers: auth_headers(user),
            as: :json

      expect(response).to have_http_status(:ok)
      expect(json["event"]["title"]).to eq("New Title")
    end

    it "only touches the submitted field — a partial update doesn't null out the rest" do
      event.update!(description: "Original description", location: "Phnom Penh")

      patch "/api/v1/events/#{event.id}",
            params: { event: { title: "New Title" } },
            headers: auth_headers(user),
            as: :json

      expect(response).to have_http_status(:ok)
      expect(json["event"]["description"]).to eq("Original description")
      expect(json["event"]["location"]).to eq("Phnom Penh")
    end

    it "ignores a client-supplied capacity/plan/is_published on update too" do
      # factory default is_published: true — request the opposite value to
      # prove it's ignored (stays true) rather than assuming a starting value.
      patch "/api/v1/events/#{event.id}",
            params: { event: { capacity: 999_999, plan: "extra_large", is_published: false } },
            headers: auth_headers(user),
            as: :json

      expect(response).to have_http_status(:ok)
      expect(event.reload.capacity).to be_nil
      expect(event.plan).to be_nil
      expect(event.is_published).to be(true)
    end

    it "adds, updates, and destroys event types via event_types_attributes" do
      to_rename = event.event_types.create!(name: "Old type", position: 0)
      to_remove = event.event_types.create!(name: "Doomed type", position: 1)

      patch "/api/v1/events/#{event.id}",
            params: {
              event: {
                event_types_attributes: [
                  { id: to_rename.id, name: "Renamed type" },
                  { id: to_remove.id, _destroy: true },
                  { name: "Brand new type", position: 2 }
                ]
              }
            },
            headers: auth_headers(user),
            as: :json

      expect(response).to have_http_status(:ok)
      names = json["event"]["event_types"].map { |t| t["name"] }
      expect(names).to contain_exactly("Renamed type", "Brand new type")
      expect(EventType.exists?(to_remove.id)).to be(false)
    end

    it "returns 422 with a usable error message for an invalid schema shape" do
      patch "/api/v1/events/#{event.id}",
            params: { event: { latitude: 11.5 } },
            headers: auth_headers(user),
            as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json["error"]).to be_present
    end

    it "returns 403 when a different user tries to update" do
      patch "/api/v1/events/#{event.id}",
            params: { event: { title: "Hijacked" } },
            headers: auth_headers(other),
            as: :json

      expect(response).to have_http_status(:forbidden)
    end

    it "returns 401 without a token" do
      patch "/api/v1/events/#{event.id}", params: { event: { title: "X" } }, as: :json
      expect(response).to have_http_status(:unauthorized)
    end
  end

  # ── DELETE /api/v1/events/:id ────────────────────────────────────────────────
  describe "DELETE /api/v1/events/:id" do
    let!(:event) { create(:event, creator: user) }

    it "deletes the event" do
      delete "/api/v1/events/#{event.id}", headers: auth_headers(user), as: :json

      expect(response).to have_http_status(:ok)
      expect(Event.find_by(id: event.id)).to be_nil
    end

    it "returns 403 when a different user tries to delete" do
      delete "/api/v1/events/#{event.id}", headers: auth_headers(other), as: :json
      expect(response).to have_http_status(:forbidden)
    end
  end
end
