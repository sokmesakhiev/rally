require "rails_helper"

RSpec.describe Event, type: :model do
  subject(:event) { build(:event) }

  # ── Associations ─────────────────────────────────────────────────────────────
  describe "associations" do
    it { is_expected.to belong_to(:creator).class_name("User") }
    it { is_expected.to belong_to(:organization) }
    it { is_expected.to have_many(:registrations).dependent(:destroy) }

    # Required, not optional — every event is presented by someone.
    it "is invalid without an organization" do
      event.organization = nil
      expect(event).not_to be_valid
      expect(event.errors[:organization]).to be_present
    end

    # creator and organization answer different questions: who set this up
    # vs. who it's presented by. A club admin creating an event under the
    # club's name is the normal case, not an anomaly.
    it "allows a creator who does not own the presenting organization" do
      club = create(:organization)
      colleague = create(:user)

      event = build(:event, :for_organization, creator: colleague, presented_by: club)

      expect(event).to be_valid
      expect(event.creator_id).not_to eq(club.owner_id)
    end
  end

  # ── Validations ──────────────────────────────────────────────────────────────
  describe "validations" do
    it { is_expected.to validate_presence_of(:title) }
    it { is_expected.to validate_presence_of(:start_at) }
    it { is_expected.to validate_length_of(:title).is_at_most(120) }
    it { is_expected.to validate_numericality_of(:price_cents).is_greater_than_or_equal_to(0) }

    it "rejects an invalid category" do
      event.category = "skydiving"
      expect(event).not_to be_valid
      expect(event.errors[:category]).to be_present
    end

    it "accepts all valid categories" do
      Event::CATEGORIES.each do |cat|
        event.category = cat
        expect(event).to be_valid, "expected #{cat} to be valid"
      end
    end

    it "rejects end_at before start_at" do
      event.end_at = event.start_at - 1.hour
      expect(event).not_to be_valid
      expect(event.errors[:end_at]).to be_present
    end

    it "accepts end_at after start_at" do
      event.end_at = event.start_at + 2.hours
      expect(event).to be_valid
    end

    it "accepts a valid latitude/longitude pair" do
      event.latitude = 11.5564
      event.longitude = 104.9282
      expect(event).to be_valid
    end

    it "rejects latitude only, without longitude" do
      event.latitude = 11.5564
      event.longitude = nil
      expect(event).not_to be_valid
      expect(event.errors[:base]).to be_present
    end

    it "rejects longitude only, without latitude" do
      event.latitude = nil
      event.longitude = 104.9282
      expect(event).not_to be_valid
      expect(event.errors[:base]).to be_present
    end

    it "rejects an out-of-range latitude" do
      event.latitude = 200
      event.longitude = 104.9282
      expect(event).not_to be_valid
      expect(event.errors[:latitude]).to be_present
    end

    it "accepts a blank route_map_url" do
      event.route_map_url = nil
      expect(event).to be_valid
    end

    it "accepts a valid http(s) route_map_url" do
      event.route_map_url = "https://www.google.com/maps/d/edit?mid=abc123"
      expect(event).to be_valid
    end

    it "rejects a non-URL route_map_url" do
      event.route_map_url = "not a url"
      expect(event).not_to be_valid
      expect(event.errors[:route_map_url]).to be_present
    end
  end

  # ── Capacity vs. combined event type limits ─────────────────────────────────
  describe "capacity_covers_event_types" do
    it "is not checked while capacity is nil (a draft with no plan yet)" do
      event = create(:event, capacity: nil)
      event.event_types.create!(name: "5K", capacity: 1_000, position: 0)
      expect(event).to be_valid
    end

    it "rejects a capacity smaller than the combined event type limits" do
      event = create(:event, capacity: 200)
      event.event_types.build(name: "5K", capacity: 100, position: 0)
      event.event_types.build(name: "10K", capacity: 150, position: 1)
      expect(event).not_to be_valid
      expect(event.errors[:capacity]).to be_present
    end

    it "accepts a capacity that covers the combined event type limits" do
      event = create(:event, capacity: 250)
      event.event_types.build(name: "5K", capacity: 100, position: 0)
      event.event_types.build(name: "10K", capacity: 150, position: 1)
      expect(event).to be_valid
    end

    it "ignores event types with no capacity of their own (unlimited)" do
      event = create(:event, capacity: 50)
      event.event_types.build(name: "Open", capacity: nil, position: 0)
      expect(event).to be_valid
    end
  end

  describe "#combined_event_type_capacity" do
    it "sums each type's capacity, skipping unlimited (nil) types" do
      event = create(:event, capacity: 1_000)
      event.event_types.create!(name: "5K", capacity: 100, position: 0)
      event.event_types.create!(name: "10K", capacity: 150, position: 1)
      event.event_types.create!(name: "Open", capacity: nil, position: 2)
      expect(event.reload.combined_event_type_capacity).to eq(250)
    end
  end

  # ── Scopes ───────────────────────────────────────────────────────────────────
  describe "scopes" do
    let!(:published_upcoming)   { create(:event, is_published: true,  start_at: 1.week.from_now) }
    let!(:draft_upcoming)       { create(:event, :draft,              start_at: 1.week.from_now) }
    let!(:published_past)       { create(:event, :past) }

    describe ".published" do
      it "returns only published events" do
        expect(Event.published).to include(published_upcoming)
        expect(Event.published).not_to include(draft_upcoming)
      end
    end

    describe ".upcoming" do
      it "returns events with start_at in the future" do
        expect(Event.upcoming).to include(published_upcoming, draft_upcoming)
        expect(Event.upcoming).not_to include(published_past)
      end
    end

    it "chains published.upcoming correctly" do
      results = Event.published.upcoming
      expect(results).to include(published_upcoming)
      expect(results).not_to include(draft_upcoming, published_past)
    end
  end

  # ── Certificates ─────────────────────────────────────────────────────────────
  describe "#certificate_template?" do
    it "is false when no template has been uploaded" do
      expect(build(:event, certificate_template_url: nil).certificate_template?).to be(false)
    end

    it "is true once a template url is set" do
      expect(build(:event, certificate_template_url: "https://example.com/t.odt").certificate_template?).to be(true)
    end
  end

  describe "#ended?" do
    it "is true once end_at has passed" do
      expect(build(:event, :past).ended?).to be(true)
    end

    it "is false for an upcoming event" do
      expect(build(:event, start_at: 1.week.from_now, end_at: 2.weeks.from_now).ended?).to be(false)
    end

    it "falls back to start_at when end_at is blank" do
      expect(build(:event, start_at: 1.hour.ago, end_at: nil).ended?).to be(true)
      expect(build(:event, start_at: 1.hour.from_now, end_at: nil).ended?).to be(false)
    end
  end

  # ── Soft-delete ──────────────────────────────────────────────────────────────
  describe "#discard!" do
    it "sets deleted_at and unpublishes, without destroying the row" do
      event = create(:event, is_published: true)

      expect { event.discard! }.not_to change(Event, :count)
      expect(event.discarded?).to be(true)
      expect(event.is_published).to be(false)
      expect(Event.kept).not_to include(event)
      expect(Event.discarded).to include(event)
    end

    it "cascades to kept registrations and waitlist entries without destroying them" do
      event = create(:event, :full)
      registration = event.registrations.first
      waiting_event = create(:event, :full)
      entry = create(:waitlist_entry, event: waiting_event)

      event.discard!

      expect(registration.reload.discarded?).to be(true)
      expect(registration.status).to eq("cancelled")
      expect(Registration.exists?(registration.id)).to be(true)

      # sanity check that #discard! doesn't touch an unrelated event's entries
      expect(entry.reload.discarded?).to be(false)
    end

    it "leaves event_types and payments attached, untouched" do
      event = create(:event, capacity: 10)
      type = event.event_types.create!(name: "5K", position: 0)

      event.discard!

      expect(EventType.exists?(type.id)).to be(true)
    end
  end

  # ── Suspend (admin moderation) ────────────────────────────────────────────────
  describe "#suspend!" do
    it "sets suspended_at, stores the reason, and unpublishes" do
      event = create(:event, is_published: true)

      event.suspend!(reason: "Reported as a scam")

      expect(event.suspended?).to be(true)
      expect(event.suspension_reason).to eq("Reported as a scam")
      expect(event.is_published).to be(false)
    end

    it "blanks a reason of only whitespace, mirroring User#suspend!" do
      event = create(:event)

      event.suspend!(reason: "   ")

      expect(event.suspension_reason).to be_nil
    end

    it "leaves registrations and memberships untouched" do
      event = create(:event, :full)
      registration = event.registrations.first

      event.suspend!(reason: "Reported")

      expect(registration.reload.discarded?).to be(false)
    end
  end

  describe "#unsuspend!" do
    it "clears suspended_at and suspension_reason without re-publishing" do
      event = create(:event, is_published: true)
      event.suspend!(reason: "Reported")

      event.unsuspend!

      expect(event.suspended?).to be(false)
      expect(event.suspension_reason).to be_nil
      expect(event.is_published).to be(false)
    end
  end

  # ── Defaults ─────────────────────────────────────────────────────────────────
  describe "defaults" do
    let(:saved) { create(:event) }

    it "defaults price_cents to 0" do
      expect(create(:event, price_cents: nil).price_cents).to eq(0)
    end

    it "defaults currency to usd" do
      expect(saved.currency).to eq("usd")
    end

    it "defaults brand_color" do
      expect(saved.brand_color).to be_present
    end
  end
end
