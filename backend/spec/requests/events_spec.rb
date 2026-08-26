require "rails_helper"

RSpec.describe "Events API", type: :request do
  # Verified by default: most specs here exercise ordinary organizer
  # behaviour, and paid events (which several of them create) require an
  # admin-verified account — see User#verified? and
  # EventsController#reject_unverified_paid_event!. The specs that are
  # actually *about* that gate create their own unverified organizer
  # explicitly, so the restriction is never something you have to infer from
  # this line.
  let(:user)  { create(:user, :verified) }
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

    it "tags the caller's own events with role: owner" do
      get "/api/v1/events/my", headers: auth_headers(user), as: :json

      returned = json["events"].find { |e| e["id"] == my_event.id }
      expect(returned["role"]).to eq("owner")
    end

    # Issue #278 — without this, an invited member accepts an invitation and
    # then has no way to reach the event at all.
    context "when the caller is a member of someone else's event, not its creator" do
      let!(:member_event) { create(:event, creator: other) }

      it "includes the event, tagged with the caller's role" do
        create(:event_membership, event: member_event, user: user, role: "manager")

        get "/api/v1/events/my", headers: auth_headers(user), as: :json

        returned = json["events"].find { |e| e["id"] == member_event.id }
        expect(returned).to be_present
        expect(returned["role"]).to eq("manager")
      end

      it "does not include an event from a discarded (soft-deleted) membership's event" do
        create(:event_membership, event: member_event, user: user, role: "viewer")
        member_event.discard!

        get "/api/v1/events/my", headers: auth_headers(user), as: :json

        ids = json["events"].map { |e| e["id"] }
        expect(ids).not_to include(member_event.id)
      end

      it "tags the event as owner, not the membership role, if the caller somehow holds both" do
        create(:event_membership, event: my_event, user: user, role: "viewer")

        get "/api/v1/events/my", headers: auth_headers(user), as: :json

        returned = json["events"].find { |e| e["id"] == my_event.id }
        expect(returned["role"]).to eq("owner")
      end
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

    it "returns role: nil for an anonymous viewer" do
      get "/api/v1/events/#{event.id}", as: :json
      expect(json["event"]["role"]).to be_nil
    end

    it "returns role: nil for a signed-in stranger" do
      get "/api/v1/events/#{event.id}", headers: auth_headers(create(:user)), as: :json
      expect(json["event"]["role"]).to be_nil
    end

    it "returns role: owner for the event's creator" do
      get "/api/v1/events/#{event.id}", headers: auth_headers(event.creator), as: :json
      expect(json["event"]["role"]).to eq("owner")
    end

    it "returns the caller's membership role for a team member" do
      manager = create(:user)
      create(:event_membership, event: event, user: manager, role: "manager")

      get "/api/v1/events/#{event.id}", headers: auth_headers(manager), as: :json
      expect(json["event"]["role"]).to eq("manager")
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

    # ── Paid events require an admin-verified organizer ──
    context "paid-event verification gating" do
      # Explicitly unverified — the outer `user` is verified (see the top of
      # this file), which is the wrong subject for these particular specs.
      let(:unverified) { create(:user) }

      it "rejects a paid event from an unverified organizer" do
        expect {
          post "/api/v1/events",
               params: valid_params.deep_merge(event: { price_cents: 2500 }),
               headers: auth_headers(unverified),
               as: :json
        }.not_to change(Event, :count)

        expect(response).to have_http_status(:unprocessable_entity)
        expect(json["code"]).to eq("verification_required")
      end

      it "rejects a paid event smuggled in via a per-type price" do
        # event-level price_cents is 0 here — the only price is on the type,
        # which EventType#effective_price_cents would still charge.
        params = valid_params.deep_merge(
          event: {
            price_cents: 0,
            event_types_attributes: [ { name: "10K", price_cents: 1500, position: 0 } ]
          }
        )

        expect {
          post "/api/v1/events", params: params, headers: auth_headers(unverified), as: :json
        }.not_to change(Event, :count)

        expect(response).to have_http_status(:unprocessable_entity)
        expect(json["code"]).to eq("verification_required")
      end

      it "allows a free event from an unverified organizer" do
        post "/api/v1/events", params: valid_params, headers: auth_headers(unverified), as: :json

        expect(response).to have_http_status(:created)
        expect(json["event"]["price_cents"]).to eq(0)
      end

      it "allows free event types (no per-type price) from an unverified organizer" do
        params = valid_params.deep_merge(
          event: { event_types_attributes: [ { name: "Fun run", position: 0 } ] }
        )

        post "/api/v1/events", params: params, headers: auth_headers(unverified), as: :json

        expect(response).to have_http_status(:created)
      end

      it "allows a paid event from a verified organizer" do
        post "/api/v1/events",
             params: valid_params.deep_merge(event: { price_cents: 2500 }),
             headers: auth_headers(user),
             as: :json

        expect(response).to have_http_status(:created)
        expect(json["event"]["price_cents"]).to eq(2500)
      end
    end

    it "emails the creator a confirmation once the event is created" do
      expect {
        perform_enqueued_jobs do
          post "/api/v1/events", params: valid_params, headers: auth_headers(user), as: :json
        end
      }.to change { ActionMailer::Base.deliveries.count }.by(1)

      mail = ActionMailer::Base.deliveries.last
      expect(mail.to).to eq([ user.email ])
      expect(mail.subject).to include("has been created")
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

    it "logs an EventActivity when price_cents changes" do
      expect {
        patch "/api/v1/events/#{event.id}",
              params: { event: { price_cents: 5000 } },
              headers: auth_headers(user),
              as: :json
      }.to change(EventActivity, :count).by(1)

      activity = EventActivity.last
      expect(activity.event).to eq(event)
      expect(activity.actor).to eq(user)
      expect(activity.action).to eq("update_event_details")
      expect(activity.metadata["price_cents"]).to eq("from" => 0, "to" => 5000)
    end

    it "logs an EventActivity when start_at/end_at change, capturing both fields" do
      new_start = 3.weeks.from_now
      new_end = 4.weeks.from_now

      patch "/api/v1/events/#{event.id}",
            params: { event: { start_at: new_start.iso8601, end_at: new_end.iso8601 } },
            headers: auth_headers(user),
            as: :json

      activity = EventActivity.last
      expect(activity.action).to eq("update_event_details")
      expect(activity.metadata.keys).to contain_exactly("start_at", "end_at")
    end

    it "does not log an EventActivity when only unrelated fields change" do
      expect {
        patch "/api/v1/events/#{event.id}",
              params: { event: { title: "New Title", location: "Siem Reap" } },
              headers: auth_headers(user),
              as: :json
      }.not_to change(EventActivity, :count)
    end

    it "does not log an EventActivity when the submitted price/dates match the current values" do
      expect {
        patch "/api/v1/events/#{event.id}",
              params: { event: { price_cents: event.price_cents } },
              headers: auth_headers(user),
              as: :json
      }.not_to change(EventActivity, :count)
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

    # Issue #278 — Manager may edit event details; Check-in and Viewer may not.
    it "allows a Manager member to update" do
      manager = create(:user)
      create(:event_membership, event: event, user: manager, role: "manager")

      patch "/api/v1/events/#{event.id}",
            params: { event: { title: "Updated by manager" } },
            headers: auth_headers(manager),
            as: :json

      expect(response).to have_http_status(:ok)
      expect(json["event"]["title"]).to eq("Updated by manager")
    end

    it "returns 403 when a Check-in member tries to update event details" do
      check_in_staff = create(:user)
      create(:event_membership, event: event, user: check_in_staff, role: "check_in")

      patch "/api/v1/events/#{event.id}",
            params: { event: { title: "Hijacked" } },
            headers: auth_headers(check_in_staff),
            as: :json

      expect(response).to have_http_status(:forbidden)
    end

    # ── Paid events require an admin-verified organizer ──
    context "paid-event verification gating" do
      # The outer `user`/`event` pair is a verified organizer and their event
      # (see the top of this file) — these specs need an unverified one, with
      # a free event of their own to try to put a price on.
      let(:unverified)  { create(:user) }
      let!(:free_event) { create(:event, creator: unverified, price_cents: 0) }

      it "blocks an unverified organizer turning a free event paid" do
        # The obvious bypass if only #create were gated: create it free, then
        # immediately edit a price onto it.
        patch "/api/v1/events/#{free_event.id}",
              params: { event: { price_cents: 2500 } },
              headers: auth_headers(unverified),
              as: :json

        expect(response).to have_http_status(:unprocessable_entity)
        expect(json["code"]).to eq("verification_required")
        expect(free_event.reload.price_cents).to eq(0)
      end

      it "blocks an unverified organizer adding a paid event type to a free event" do
        patch "/api/v1/events/#{free_event.id}",
              params: {
                event: { event_types_attributes: [ { name: "10K", price_cents: 1500, position: 0 } ] }
              },
              headers: auth_headers(unverified),
              as: :json

        expect(response).to have_http_status(:unprocessable_entity)
        expect(json["code"]).to eq("verification_required")
        expect(free_event.reload.event_types).to be_empty
      end

      it "allows an unverified organizer to keep editing a free event" do
        patch "/api/v1/events/#{free_event.id}",
              params: { event: { title: "Still Free" } },
              headers: auth_headers(unverified),
              as: :json

        expect(response).to have_http_status(:ok)
        expect(free_event.reload.title).to eq("Still Free")
      end

      it "allows a verified organizer to make an event paid" do
        patch "/api/v1/events/#{event.id}",
              params: { event: { price_cents: 2500 } },
              headers: auth_headers(user),
              as: :json

        expect(response).to have_http_status(:ok)
        expect(event.reload.price_cents).to eq(2500)
      end

      it "lets an organizer keep managing an already-paid event after verification is revoked" do
        # Only the free → paid transition is gated. An event created while
        # verified stays fully manageable — its participants already paid.
        organizer = create(:user, :verified)
        paid_event = create(:event, :paid, creator: organizer)
        organizer.unverify!

        patch "/api/v1/events/#{paid_event.id}",
              params: { event: { title: "Renamed", price_cents: 3000 } },
              headers: auth_headers(organizer),
              as: :json

        expect(response).to have_http_status(:ok)
        expect(paid_event.reload.title).to eq("Renamed")
        expect(paid_event.price_cents).to eq(3000)
      end
    end

    it "emails active registrants when the price changes" do
      registration = create(:registration, event: event)

      expect {
        perform_enqueued_jobs do
          patch "/api/v1/events/#{event.id}",
                params: { event: { price_cents: 2500 } },
                headers: auth_headers(user),
                as: :json
        end
      }.to change { ActionMailer::Base.deliveries.count }.by(1)

      mail = ActionMailer::Base.deliveries.last
      expect(mail.to).to eq([ registration.user.email ])
      expect(mail.subject).to include("Details changed")
    end

    it "emails active registrants when start_at changes" do
      registration = create(:registration, event: event)
      new_start = event.start_at + 3.days

      expect {
        perform_enqueued_jobs do
          patch "/api/v1/events/#{event.id}",
                params: { event: { start_at: new_start.iso8601 } },
                headers: auth_headers(user),
                as: :json
        end
      }.to change { ActionMailer::Base.deliveries.count }.by(1)

      expect(ActionMailer::Base.deliveries.last.to).to eq([ registration.user.email ])
    end

    it "does not email registrants when only unrelated fields change" do
      create(:registration, event: event)

      expect {
        perform_enqueued_jobs do
          patch "/api/v1/events/#{event.id}",
                params: { event: { title: "New Title" } },
                headers: auth_headers(user),
                as: :json
        end
      }.not_to change { ActionMailer::Base.deliveries.count }
    end

    it "does not email a registrant who opted out of this notification" do
      registration = create(:registration, event: event)
      registration.user.profile.update!(notify_event_details_changed: false)

      expect {
        perform_enqueued_jobs do
          patch "/api/v1/events/#{event.id}",
                params: { event: { price_cents: 2500 } },
                headers: auth_headers(user),
                as: :json
        end
      }.not_to change { ActionMailer::Base.deliveries.count }
    end
  end

  # ── GET /api/v1/events/:id/activity ──────────────────────────────────────────
  # (Was accidentally duplicated as two identical describe blocks — collapsed
  # to one while touching this section for issue #278's role-gating specs;
  # no coverage lost, the two blocks ran the exact same examples twice.)
  describe "GET /api/v1/events/:id/activity" do
    let!(:event) { create(:event, creator: user) }

    it "returns the event's activity, newest first" do
      older = EventActivity.log!(
        event: event, actor: user, action: "remove_participant",
        metadata: { "participant_name" => "Dara Kim" }
      )
      older.update_column(:created_at, 1.day.ago)
      newer = EventActivity.log!(
        event: event, actor: user, action: "update_event_details",
        metadata: { "price_cents" => { "from" => 0, "to" => 5000 } }
      )

      get "/api/v1/events/#{event.id}/activity", headers: auth_headers(user), as: :json

      expect(response).to have_http_status(:ok)
      ids = json["activities"].map { |a| a["id"] }
      expect(ids).to eq([ newer.id, older.id ])
      expect(json["activities"].first["action"]).to eq("update_event_details")
      expect(json["activities"].first["actor_name"]).to be_present
    end

    it "returns 404 for a non-organizer" do
      get "/api/v1/events/#{event.id}/activity", headers: auth_headers(other), as: :json
      expect(response).to have_http_status(:not_found)
    end

    it "returns 401 without a token" do
      get "/api/v1/events/#{event.id}/activity", as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    # Issue #278 — Viewer may read the activity log; Check-in may not.
    it "allows a Viewer member to view the activity log" do
      viewer = create(:user)
      create(:event_membership, event: event, user: viewer, role: "viewer")

      get "/api/v1/events/#{event.id}/activity", headers: auth_headers(viewer), as: :json

      expect(response).to have_http_status(:ok)
    end

    it "returns 404 for a Check-in member" do
      check_in_staff = create(:user)
      create(:event_membership, event: event, user: check_in_staff, role: "check_in")

      get "/api/v1/events/#{event.id}/activity", headers: auth_headers(check_in_staff), as: :json

      expect(response).to have_http_status(:not_found)
    end
  end

  # ── DELETE /api/v1/events/:id ────────────────────────────────────────────────
  describe "DELETE /api/v1/events/:id" do
    let!(:event) { create(:event, creator: user) }

    it "soft-deletes the event rather than destroying the row" do
      # See Event#discard! — the row (and its registrations/payments)
      # survives, just hidden from normal reads.
      delete "/api/v1/events/#{event.id}", headers: auth_headers(user), as: :json

      expect(response).to have_http_status(:ok)
      expect(Event.kept.find_by(id: event.id)).to be_nil
      expect(event.reload.discarded?).to be(true)
      expect(event.is_published).to be(false)
    end

    it "returns 403 when a different user tries to delete" do
      delete "/api/v1/events/#{event.id}", headers: auth_headers(other), as: :json
      expect(response).to have_http_status(:forbidden)
    end

    # Issue #278 — delete stays owner-only even for Manager: it destroys work
    # that isn't theirs to take down.
    it "returns 403 when a Manager member tries to delete" do
      manager = create(:user)
      create(:event_membership, event: event, user: manager, role: "manager")

      delete "/api/v1/events/#{event.id}", headers: auth_headers(manager), as: :json

      expect(response).to have_http_status(:forbidden)
      expect(Event.kept.find_by(id: event.id)).to be_present
    end
  end
end
