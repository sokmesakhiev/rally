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
