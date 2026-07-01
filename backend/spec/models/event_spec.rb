require "rails_helper"

RSpec.describe Event, type: :model do
  subject(:event) { build(:event) }

  # ── Associations ─────────────────────────────────────────────────────────────
  describe "associations" do
    it { is_expected.to belong_to(:creator).class_name("User") }
    it { is_expected.to have_many(:registrations).dependent(:destroy) }
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
