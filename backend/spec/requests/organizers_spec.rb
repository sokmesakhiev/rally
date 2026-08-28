require "rails_helper"

# organization-identity-tickets.md's Ticket F (#335) — the public organizer
# page. Unauthenticated and world-readable, so the leak test near the bottom
# is the load-bearing one.
RSpec.describe "Public organizer page API", type: :request do
  let(:organizer) { create(:user, email: "owner@example.com") }
  let!(:organization) do
    create(:organization, :branded,
           owner: organizer,
           name: "Phnom Penh Runners",
           description: "A running club.",
           contact_email: "hello@example.com",
           contact_phone: "012345678")
  end

  # Traits pass through positionally so callers can ask for :draft.
  def visible_event(*traits, **attrs)
    create(:event, :for_organization, *traits,
           presented_by: organization, creator: organizer, **attrs)
  end

  describe "GET /api/v1/organizers/:slug" do
    it "is readable with no token at all" do
      get "/api/v1/organizers/#{organization.slug}", as: :json

      expect(response).to have_http_status(:ok)
      expect(json["organizer"]["name"]).to eq("Phnom Penh Runners")
    end

    it "returns identity, branding, contact and social links" do
      get "/api/v1/organizers/#{organization.slug}", as: :json

      organizer_json = json["organizer"]
      expect(organizer_json["slug"]).to eq(organization.slug)
      expect(organizer_json["description"]).to eq("A running club.")
      expect(organizer_json["logo_url"]).to be_present
      expect(organizer_json["banner_url"]).to be_present
      expect(organizer_json["contact_email"]).to eq("hello@example.com")
      expect(organizer_json["contact_phone"]).to eq("012345678")
      expect(organizer_json["website"]).to be_present
    end

    it "reports verification status" do
      get "/api/v1/organizers/#{organization.slug}", as: :json
      expect(json["organizer"]["verified"]).to be(false)

      organization.verify!
      get "/api/v1/organizers/#{organization.slug}", as: :json
      expect(json["organizer"]["verified"]).to be(true)
    end

    it "returns 404 for an unknown slug" do
      get "/api/v1/organizers/no-such-organizer", as: :json

      expect(response).to have_http_status(:not_found)
    end

    it "returns 404 for a discarded organization" do
      organization.discard!

      get "/api/v1/organizers/#{organization.slug}", as: :json

      expect(response).to have_http_status(:not_found)
    end
  end

  # ── Suspension ───────────────────────────────────────────────────────────────
  describe "suspended organizers" do
    it "returns 404 when the organization itself is suspended" do
      organization.suspend!(reason: "Reported as fraudulent")

      get "/api/v1/organizers/#{organization.slug}", as: :json

      expect(response).to have_http_status(:not_found)
    end

    # Organization#suspended? already derives from the owner, so this works
    # without Ticket J's event-level cascade existing yet.
    it "returns 404 when the organization's owner is suspended" do
      organizer.suspend!(reason: "Fraud")

      get "/api/v1/organizers/#{organization.slug}", as: :json

      expect(response).to have_http_status(:not_found)
    end

    it "becomes readable again once the owner is unsuspended" do
      organizer.suspend!
      organizer.unsuspend!

      get "/api/v1/organizers/#{organization.slug}", as: :json

      expect(response).to have_http_status(:ok)
    end
  end

  # ── Event listing ────────────────────────────────────────────────────────────
  describe "event listing" do
    it "lists published upcoming events" do
      upcoming = visible_event(title: "Sunrise 10K", start_at: 1.week.from_now, end_at: 1.week.from_now + 2.hours)

      get "/api/v1/organizers/#{organization.slug}", as: :json

      expect(json["organizer"]["upcoming_events"].map { |e| e["id"] }).to eq([ upcoming.id ])
    end

    it "lists past events separately, newest first" do
      older = visible_event(start_at: 8.weeks.ago, end_at: 8.weeks.ago + 2.hours)
      newer = visible_event(start_at: 2.weeks.ago, end_at: 2.weeks.ago + 2.hours)

      get "/api/v1/organizers/#{organization.slug}", as: :json

      expect(json["organizer"]["past_events"].map { |e| e["id"] }).to eq([ newer.id, older.id ])
    end

    it "excludes draft events" do
      draft = visible_event(:draft, start_at: 1.week.from_now)

      get "/api/v1/organizers/#{organization.slug}", as: :json

      expect(json["organizer"]["upcoming_events"].map { |e| e["id"] }).not_to include(draft.id)
    end

    it "excludes discarded events" do
      discarded = visible_event(start_at: 1.week.from_now)
      discarded.discard!

      get "/api/v1/organizers/#{organization.slug}", as: :json

      expect(json["organizer"]["upcoming_events"]).to be_empty
    end

    it "excludes individually suspended events" do
      suspended = visible_event(start_at: 1.week.from_now)
      suspended.suspend!(reason: "Reported")

      get "/api/v1/organizers/#{organization.slug}", as: :json

      expect(json["organizer"]["upcoming_events"]).to be_empty
    end

    it "never lists another organization's events" do
      someone_elses = create(:event, start_at: 1.week.from_now)

      get "/api/v1/organizers/#{organization.slug}", as: :json

      expect(json["organizer"]["upcoming_events"].map { |e| e["id"] }).not_to include(someone_elses.id)
    end

    # Unauthenticated endpoint — an organizer with years of history shouldn't
    # return hundreds of rows to anyone who asks.
    it "caps the past events returned" do
      12.times { |i| visible_event(start_at: (i + 2).weeks.ago, end_at: (i + 2).weeks.ago + 2.hours) }

      get "/api/v1/organizers/#{organization.slug}", as: :json

      expect(json["organizer"]["past_events"].length)
        .to eq(Api::V1::OrganizersController::PAST_EVENTS_LIMIT)
    end
  end

  # ── Trust signals ────────────────────────────────────────────────────────────
  describe "trust signals" do
    it "reports member_since" do
      get "/api/v1/organizers/#{organization.slug}", as: :json

      expect(Time.parse(json["organizer"]["member_since"]))
        .to be_within(5.seconds).of(organization.created_at)
    end

    it "counts only events that have actually finished" do
      visible_event(start_at: 2.weeks.ago, end_at: 2.weeks.ago + 2.hours)
      visible_event(start_at: 3.weeks.ago, end_at: 3.weeks.ago + 2.hours)
      visible_event(start_at: 1.week.from_now)  # upcoming — no track record yet

      get "/api/v1/organizers/#{organization.slug}", as: :json

      expect(json["organizer"]["events_run"]).to eq(2)
    end

    it "excludes drafts and suspended events from events_run" do
      visible_event(:draft, start_at: 2.weeks.ago, end_at: 2.weeks.ago + 2.hours)
      visible_event(start_at: 3.weeks.ago, end_at: 3.weeks.ago + 2.hours)
        .suspend!(reason: "Reported")

      get "/api/v1/organizers/#{organization.slug}", as: :json

      expect(json["organizer"]["events_run"]).to eq(0)
    end

    it "sums registrations across finished events" do
      past = visible_event(start_at: 2.weeks.ago, end_at: 2.weeks.ago + 2.hours)
      create_list(:registration, 3, event: past)

      get "/api/v1/organizers/#{organization.slug}", as: :json

      expect(json["organizer"]["participants_hosted"]).to eq(3)
    end

    it "excludes cancelled registrations" do
      past = visible_event(start_at: 2.weeks.ago, end_at: 2.weeks.ago + 2.hours)
      create_list(:registration, 2, event: past)
      create(:registration, event: past, status: "cancelled")

      get "/api/v1/organizers/#{organization.slug}", as: :json

      expect(json["organizer"]["participants_hosted"]).to eq(2)
    end

    it "excludes registrations for events that haven't happened yet" do
      upcoming = visible_event(start_at: 1.week.from_now)
      create_list(:registration, 4, event: upcoming)

      get "/api/v1/organizers/#{organization.slug}", as: :json

      expect(json["organizer"]["participants_hosted"]).to eq(0)
    end

    it "is zero for a brand-new organizer" do
      get "/api/v1/organizers/#{organization.slug}", as: :json

      expect(json["organizer"]["events_run"]).to eq(0)
      expect(json["organizer"]["participants_hosted"]).to eq(0)
    end
  end

  # ── The one that matters ─────────────────────────────────────────────────────
  describe "private data" do
    # This endpoint is world-readable, so assert on the whole serialized body
    # rather than field by field — a future addition to the payload has to
    # actively pass this, not merely avoid the keys someone thought to check.
    it "leaks no payment credentials, account email, or internal ids" do
      organization.update!(
        payway_merchant_id: "merchant_secret_123",
        payway_api_key: "api_key_abcdef1234",
        payway_rsa_public_key: "-----BEGIN PUBLIC KEY-----"
      )
      visible_event(start_at: 1.week.from_now)

      get "/api/v1/organizers/#{organization.slug}", as: :json

      expect(response.body).not_to include("merchant_secret_123")
      expect(response.body).not_to include("api_key_abcdef1234")
      expect(response.body).not_to include("BEGIN PUBLIC KEY")
      # The address the organizer signs in with — distinct from the
      # contact_email they chose to publish.
      expect(response.body).not_to include("owner@example.com")

      organizer_json = json["organizer"]
      %w[payway_merchant_id payway_api_key payway_api_key_masked
         payway_rsa_public_key payway_configured payway_refund_configured
         owner_id id suspended suspended_at].each do |forbidden|
        expect(organizer_json).not_to have_key(forbidden)
      end
    end

    it "does not expose creator or plan details on listed events" do
      visible_event(start_at: 1.week.from_now)

      get "/api/v1/organizers/#{organization.slug}", as: :json

      event_json = json["organizer"]["upcoming_events"].first
      %w[creator_id organization_id plan capacity suspended suspension_reason
         is_published].each do |forbidden|
        expect(event_json).not_to have_key(forbidden)
      end
    end
  end
end
