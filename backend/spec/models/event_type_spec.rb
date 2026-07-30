require "rails_helper"

RSpec.describe EventType do
  describe "validations" do
    subject { build_event_type }

    def build_event_type(**attrs)
      create(:event).event_types.build({ name: "5K", position: 0 }.merge(attrs))
    end

    it { is_expected.to be_valid }

    it "requires a name" do
      expect(build_event_type(name: nil)).not_to be_valid
    end

    it "rejects a name longer than 120 characters" do
      expect(build_event_type(name: "a" * 121)).not_to be_valid
      expect(build_event_type(name: "a" * 120)).to be_valid
    end

    it "requires a position" do
      expect(build_event_type(position: nil)).not_to be_valid
    end

    it "allows a nil capacity (meaning unlimited) but rejects zero or negative" do
      expect(build_event_type(capacity: nil)).to be_valid
      expect(build_event_type(capacity: 1)).to be_valid
      expect(build_event_type(capacity: 0)).not_to be_valid
      expect(build_event_type(capacity: -1)).not_to be_valid
    end

    it "allows a nil price (inherit from event) and zero, but rejects negative" do
      expect(build_event_type(price_cents: nil)).to be_valid
      expect(build_event_type(price_cents: 0)).to be_valid
      expect(build_event_type(price_cents: -1)).not_to be_valid
    end
  end

  describe "#effective_price_cents" do
    it "uses the type's own price when it has one" do
      event = create(:event, price_cents: 2500)
      type = event.event_types.create!(name: "5K", position: 0, price_cents: 1000)

      expect(type.effective_price_cents).to eq(1000)
    end

    it "falls back to the event's price when the type has none" do
      event = create(:event, price_cents: 2500)
      type = event.event_types.create!(name: "5K", position: 0, price_cents: nil)

      expect(type.effective_price_cents).to eq(2500)
    end

    it "treats a type price of 0 as a real price, not as 'unset'" do
      # The distinction matters: a free type inside a paid event is a real
      # configuration, and `price_cents.nil?` (not `.blank?`/falsy) is what
      # makes it work.
      event = create(:event, price_cents: 2500)
      type = event.event_types.create!(name: "Kids fun run", position: 0, price_cents: 0)

      expect(type.effective_price_cents).to eq(0)
    end
  end

  describe "#spots_remaining" do
    let(:event) { create(:event) }

    it "returns nil for an uncapped type" do
      type = event.event_types.create!(name: "5K", position: 0, capacity: nil)

      expect(type.spots_remaining).to be_nil
    end

    it "returns the full capacity when nobody has registered" do
      type = event.event_types.create!(name: "5K", position: 0, capacity: 10)

      expect(type.spots_remaining).to eq(10)
    end

    it "subtracts existing registrations" do
      type = event.event_types.create!(name: "5K", position: 0, capacity: 10)
      2.times do
        create(:registration, event: event).registration_event_types.create!(event_type: type)
      end

      expect(type.reload.spots_remaining).to eq(8)
    end

    it "floors at zero rather than going negative" do
      # Capacity can be lowered by an organizer after people have registered,
      # so "taken > capacity" is reachable and must not render as a negative
      # number of spots in the UI.
      type = event.event_types.create!(name: "5K", position: 0, capacity: 2)
      3.times do
        create(:registration, event: event).registration_event_types.create!(event_type: type)
      end
      type.update_column(:capacity, 2)

      expect(type.reload.spots_remaining).to eq(0)
    end

    it "reads a preloaded association without issuing another query" do
      # Regression guard for the N+1 fixed by switching .count → .size: with
      # registration_event_types eager-loaded, asking for spots_remaining must
      # not hit the database again.
      type = event.event_types.create!(name: "5K", position: 0, capacity: 10)
      create(:registration, event: event).registration_event_types.create!(event_type: type)

      loaded = EventType.includes(:registration_event_types).find(type.id)

      queries = 0
      counter = ->(*, payload) { queries += 1 unless payload[:sql].match?(/\A(BEGIN|COMMIT|SAVEPOINT|RELEASE)/) }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
        expect(loaded.spots_remaining).to eq(9)
      end

      expect(queries).to eq(0)
    end
  end

  describe "#full?" do
    let(:event) { create(:event) }

    it "is false for an uncapped type no matter how many have registered" do
      type = event.event_types.create!(name: "5K", position: 0, capacity: nil)
      3.times do
        create(:registration, event: event).registration_event_types.create!(event_type: type)
      end

      expect(type.reload).not_to be_full
    end

    it "is false below capacity and true once capacity is reached" do
      type = event.event_types.create!(name: "5K", position: 0, capacity: 2)
      expect(type).not_to be_full

      create(:registration, event: event).registration_event_types.create!(event_type: type)
      expect(type.reload).not_to be_full

      create(:registration, event: event).registration_event_types.create!(event_type: type)
      expect(type.reload).to be_full
    end
  end
end
