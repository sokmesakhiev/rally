require "rails_helper"

RSpec.describe Registrations::Summary do
  let(:event) { create(:event, price_cents: 2500) }

  # The whole reason this class exists: these figures used to be computed in
  # JavaScript over the full registration list. Once that list is paginated,
  # anything derived from its length is wrong — so these assertions are what
  # stands between a paginated table and a revenue card reporting one page.
  it "counts and sums across every registration, not a page of them" do
    create_list(:registration, 30, event: event, payment_status: "paid", amount_paid_cents: 2500)
    create_list(:registration, 12, event: event, payment_status: "unpaid", amount_paid_cents: 0)

    summary = described_class.call(event)

    expect(summary.total).to eq(42)
    expect(summary.paid).to eq(30)
    expect(summary.unpaid).to eq(12)
    expect(summary.revenue_cents).to eq(75_000)
  end

  it "counts check-ins" do
    create(:registration, event: event, checked_in_at: Time.current)
    create_list(:registration, 3, event: event)

    expect(described_class.call(event).checked_in).to eq(1)
  end

  # SUM over no rows is NULL in SQL, and a nil here renders as "$NaN".
  it "reports zero revenue for an event with no registrations" do
    summary = described_class.call(event)

    expect(summary.total).to eq(0)
    expect(summary.revenue_cents).to eq(0)
    expect(summary.revenue_cents).to be_a(Integer)
  end

  # Matches what the list endpoint shows, so the count under the table can't
  # disagree with the table.
  it "excludes discarded registrations" do
    create_list(:registration, 2, event: event)
    create(:registration, event: event).discard!

    expect(described_class.call(event).total).to eq(2)
  end

  # Deliberately *not* `active`: a cancelled registration is hidden from
  # capacity but still listed for the organizer, so it has to be counted here.
  it "includes cancelled registrations, matching the organizer's list" do
    create(:registration, event: event, status: "cancelled")

    expect(described_class.call(event).total).to eq(1)
  end

  describe "#by_event_type" do
    # No :event_type factory in this project — types are created through the
    # event and joined to a registration via registration_event_types, same as
    # spec/models/event_type_spec.rb does it.
    let(:five_k) { event.event_types.create!(name: "5K", position: 0) }
    let(:ten_k) { event.event_types.create!(name: "10K", position: 1) }

    def register_for(type)
      create(:registration, event: event).registration_event_types.create!(event_type: type)
    end

    it "counts registrations per type in one grouped query" do
      register_for(five_k)
      register_for(five_k)
      register_for(ten_k)

      counts = described_class.call(event).by_event_type

      expect(counts[five_k.id]).to eq(2)
      expect(counts[ten_k.id]).to eq(1)
    end

    # Every type present even at zero, so the frontend can map over the event's
    # types without guarding for missing keys.
    it "includes types nobody has registered for, as zero" do
      five_k
      ten_k
      register_for(five_k)

      expect(described_class.call(event).by_event_type).to eq({ five_k.id => 1, ten_k.id => 0 })
    end
  end
end
