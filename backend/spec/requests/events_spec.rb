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

      # One COUNT for pagination meta, one for events, one for event_types,
      # one for registration_event_types (the last three via .includes) — not
      # one additional COUNT per event type. Generous upper bound so this
      # doesn't become flaky against unrelated query count changes elsewhere.
      expect(query_count).to be <= 6
    end

    # ── search / filter / pagination ──
    #
    # None of the `get` calls below pass `as: :json` alongside `params:`.
    # Rails' integration test helper (ActionDispatch::Integration::Session
    # #process) intentionally rewrites `get path, params: {...}, as: :json`
    # into an actual POST with an `X-Http-Method-Override: GET` header,
    # since a GET request can't carry a JSON body per the HTTP spec — see
    # actionpack's testing/integration.rb and
    # https://github.com/rails/rails/issues/45409. That POST then hits
    # whatever POST route exists at the same path (`events#create` here),
    # which 401s because it requires auth. `set_default_format` in
    # ApplicationController forces `request.format = :json` regardless, so
    # dropping `as: :json` here doesn't change how the response is parsed.
    describe "search, filtering and pagination" do
      it "returns pagination meta alongside the events" do
        get "/api/v1/events", as: :json

        expect(json["meta"]).to include(
          "page" => 1,
          "per_page" => EventIndexRequestSchema::DEFAULT_PER_PAGE
        )
        expect(json["meta"]["total_count"]).to be_a(Integer)
      end

      it "filters by a free-text query across title, description and location" do
        by_title = create(:event, title: "Angkor Wat Half Marathon", is_published: true,
                                  start_at: 1.week.from_now)
        by_location = create(:event, title: "Morning ride", location: "Angkor Archaeological Park",
                                     is_published: true, start_at: 1.week.from_now)
        by_description = create(:event, title: "Charity run", description: "Loops around Angkor",
                                        is_published: true, start_at: 1.week.from_now)
        unrelated = create(:event, title: "Phnom Penh Swim", description: "Pool event",
                                   location: "Phnom Penh", is_published: true, start_at: 1.week.from_now)

        get "/api/v1/events", params: { q: "angkor" }

        ids = json["events"].map { |e| e["id"] }
        expect(ids).to include(by_title.id, by_location.id, by_description.id)
        expect(ids).not_to include(unrelated.id)
      end

      it "matches the query case-insensitively and on partial words" do
        event = create(:event, title: "Mekong Trail Ultra", is_published: true, start_at: 1.week.from_now)

        get "/api/v1/events", params: { q: "MEKO" }

        expect(json["events"].map { |e| e["id"] }).to include(event.id)
      end

      it "treats % and _ in the query as literal characters, not wildcards" do
        # Without sanitize_sql_like, "%" would match every event.
        create(:event, title: "Normal event", is_published: true, start_at: 1.week.from_now)
        literal = create(:event, title: "50% off entry", is_published: true, start_at: 1.week.from_now)

        get "/api/v1/events", params: { q: "50%" }

        expect(json["events"].map { |e| e["id"] }).to eq([ literal.id ])
      end

      it "ignores a blank query rather than matching nothing" do
        event = create(:event, is_published: true, start_at: 1.week.from_now)

        get "/api/v1/events", params: { q: "   " }

        expect(json["events"].map { |e| e["id"] }).to include(event.id)
      end

      it "filters by category" do
        running = create(:event, category: "running", is_published: true, start_at: 1.week.from_now)
        cycling = create(:event, category: "cycling", is_published: true, start_at: 1.week.from_now)

        get "/api/v1/events", params: { category: "running" }

        ids = json["events"].map { |e| e["id"] }
        expect(ids).to include(running.id)
        expect(ids).not_to include(cycling.id)
      end

      it "returns 422 for an unknown category rather than silently empty results" do
        get "/api/v1/events", params: { category: "quidditch" }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(json["error"]).to be_present
      end

      it "combines a query and a category filter" do
        match = create(:event, title: "Riverside Run", category: "running",
                               is_published: true, start_at: 1.week.from_now)
        wrong_category = create(:event, title: "Riverside Ride", category: "cycling",
                                       is_published: true, start_at: 1.week.from_now)

        get "/api/v1/events", params: { q: "riverside", category: "running" }

        ids = json["events"].map { |e| e["id"] }
        expect(ids).to eq([ match.id ])
        expect(ids).not_to include(wrong_category.id)
      end

      it "paginates, reporting an accurate total across pages" do
        # destroy_all, not delete_all — delete_all is a raw bulk DELETE that
        # skips dependent: :destroy, so it 500s with a FK violation the
        # moment any leftover event (from this file or elsewhere) has a
        # registration/event_type/etc. attached.
        Event.destroy_all
        5.times do |i|
          create(:event, is_published: true, start_at: (i + 1).days.from_now)
        end

        get "/api/v1/events", params: { page: 1, per_page: 2 }
        expect(json["events"].size).to eq(2)
        expect(json["meta"]).to include("page" => 1, "per_page" => 2, "total_count" => 5, "total_pages" => 3)
        first_page_ids = json["events"].map { |e| e["id"] }

        get "/api/v1/events", params: { page: 2, per_page: 2 }
        expect(json["events"].size).to eq(2)
        expect(json["events"].map { |e| e["id"] }).not_to match_array(first_page_ids)

        get "/api/v1/events", params: { page: 3, per_page: 2 }
        expect(json["events"].size).to eq(1)
      end

      it "counts only matching events in total_count, not the whole table" do
        Event.destroy_all
        create(:event, title: "Findable", is_published: true, start_at: 1.week.from_now)
        3.times { create(:event, title: "Other", is_published: true, start_at: 1.week.from_now) }

        get "/api/v1/events", params: { q: "findable", per_page: 2 }

        expect(json["meta"]["total_count"]).to eq(1)
        expect(json["meta"]["total_pages"]).to eq(1)
      end

      it "returns an empty page and zero total_pages when nothing matches" do
        get "/api/v1/events", params: { q: "no-such-event-anywhere" }

        expect(response).to have_http_status(:ok)
        expect(json["events"]).to eq([])
        expect(json["meta"]["total_count"]).to eq(0)
        expect(json["meta"]["total_pages"]).to eq(0)
      end

      it "returns an empty list for a page past the end" do
        get "/api/v1/events", params: { page: 999, per_page: 10 }

        expect(response).to have_http_status(:ok)
        expect(json["events"]).to eq([])
      end

      it "rejects a non-positive page" do
        get "/api/v1/events", params: { page: 0 }
        expect(response).to have_http_status(:unprocessable_entity)
      end

      it "rejects a per_page above the maximum instead of silently clamping" do
        get "/api/v1/events",
            params: { per_page: EventIndexRequestSchema::MAX_PER_PAGE + 1 }

        expect(response).to have_http_status(:unprocessable_entity)
      end

      it "rejects a non-numeric page" do
        get "/api/v1/events", params: { page: "abc" }
        expect(response).to have_http_status(:unprocessable_entity)
      end

      it "still excludes drafts and past events when searching" do
        # The search/filter path must not accidentally bypass the published /
        # upcoming scoping — that would leak unpublished events publicly.
        draft = create(:event, :draft, title: "Secret Marathon", start_at: 1.week.from_now)
        past = create(:event, :past, title: "Secret Marathon")

        get "/api/v1/events", params: { q: "secret marathon" }

        ids = json["events"].map { |e| e["id"] }
        expect(ids).not_to include(draft.id, past.id)
      end
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
