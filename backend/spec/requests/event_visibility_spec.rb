require "rails_helper"

# Unlisted events: hidden from every public listing, still reachable and
# registerable by anyone holding the URL.
#
# The whole implementation is one `where` in Event.publicly_visible, because
# that scope is the single chokepoint all four public read paths already go
# through. These examples exercise the paths rather than the scope, so that
# adding a fifth listing that bypasses it fails here rather than shipping.
RSpec.describe "Event visibility", type: :request do
  let(:owner) { create(:user) }
  let(:organization) { create(:organization, owner: owner) }

  # The factory already defaults `is_published: true` — there's a `:draft`
  # trait for the other direction, not a `:published` one.
  def published_event(visibility:, **attrs)
    create(:event, creator: owner, organization: organization,
                   visibility: visibility, start_at: 1.week.from_now, **attrs)
  end

  describe "the public catalogue" do
    it "lists a public event and omits an unlisted one" do
      listed = published_event(visibility: "public", title: "Open 10K")
      hidden = published_event(visibility: "unlisted", title: "Company Fun Run")

      get "/api/v1/events"

      ids = json["events"].map { |e| e["id"] }
      expect(ids).to include(listed.id)
      expect(ids).not_to include(hidden.id)
    end

    it "omits an unlisted event from search results too" do
      published_event(visibility: "unlisted", title: "Company Fun Run")

      get "/api/v1/events", params: { q: "Company" }

      expect(json["events"]).to be_empty
    end
  end

  describe "the organizer's public profile" do
    it "omits an unlisted event" do
      listed = published_event(visibility: "public")
      hidden = published_event(visibility: "unlisted")

      get "/api/v1/organizers/#{organization.slug}"

      # `upcoming_events` / `past_events`, not a flat `events` — both are built
      # from the same `publicly_visible` relation, so filtering it covers both.
      ids = json["organizer"]["upcoming_events"].map { |e| e["id"] }
      expect(ids).to include(listed.id)
      expect(ids).not_to include(hidden.id)
    end
  end

  # This is what "unlisted" means, as opposed to "private". If these two ever
  # start failing, the feature has quietly become something else and the UI
  # copy ("anyone with the link can register") is now a lie.
  describe "a link to an unlisted event" do
    it "opens for an anonymous visitor" do
      event = published_event(visibility: "unlisted")

      get "/api/v1/events/#{event.id}"

      expect(response).to have_http_status(:ok)
      expect(json["event"]["visibility"]).to eq("unlisted")
    end

    it "accepts a registration" do
      event = published_event(visibility: "unlisted", capacity: 10)

      post "/api/v1/events/#{event.id}/registrations", headers: auth_headers(create(:user))

      expect(response).to have_http_status(:created)
    end
  end

  describe "the organizer's own views" do
    it "still shows their unlisted event in my_events" do
      event = published_event(visibility: "unlisted")

      get "/api/v1/events/my", headers: auth_headers(owner)

      expect(json["events"].map { |e| e["id"] }).to include(event.id)
    end
  end

  describe "setting it" do
    it "defaults to public so nothing existing changes meaning" do
      expect(create(:event).visibility).to eq("public")
    end

    it "can be set at creation" do
      post "/api/v1/events",
           params: { event: { title: "Ride", category: "cycling",
                              start_at: 1.week.from_now.iso8601,
                              organization_id: organization.id,
                              visibility: "unlisted" } },
           headers: auth_headers(owner),
           as: :json

      expect(response).to have_http_status(:created)
      expect(json["event"]["visibility"]).to eq("unlisted")
    end

    it "can be flipped later" do
      event = published_event(visibility: "public")

      patch "/api/v1/events/#{event.id}",
            params: { event: { visibility: "unlisted" } },
            headers: auth_headers(owner),
            as: :json

      expect(response).to have_http_status(:ok)
      expect(event.reload).to be_unlisted
    end

    it "rejects a value outside the set" do
      post "/api/v1/events",
           params: { event: { title: "Ride", category: "cycling",
                              start_at: 1.week.from_now.iso8601,
                              organization_id: organization.id,
                              visibility: "secret" } },
           headers: auth_headers(owner),
           as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(json["error"]).to include("visibility")
    end
  end
end
