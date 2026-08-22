require "rails_helper"

RSpec.describe Waitlists::PromoteNext do
  # rails_helper.rb only wires ActiveJob::TestHelper (perform_enqueued_jobs)
  # into `type: :request` specs, since that's normally the only place a
  # deliver_later call gets asserted on. This is a plain service spec (no
  # `type:`, and "services" isn't one of RSpec's file-location-inferred
  # types), so it needs the helper included directly to use it below.
  include ActiveJob::TestHelper

  describe ".call" do
    it "promotes the longest-waiting entry into a confirmed registration when a spot opens up" do
      event = create(:event, capacity: 1)
      holder = create(:registration, event: event)
      waiter = create(:waitlist_entry, event: event)

      holder.destroy! # frees the one spot
      promoted = described_class.call(event)

      expect(promoted.size).to eq(1)
      registration = promoted.first
      expect(registration.user_id).to eq(waiter.user_id)
      expect(registration.status).to eq("confirmed")
      expect(waiter.reload.status).to eq("promoted")
    end

    it "promotes strictly in FIFO order" do
      event = create(:event, capacity: 1)
      holder = create(:registration, event: event)
      first  = create(:waitlist_entry, event: event, created_at: 2.hours.ago)
      second = create(:waitlist_entry, event: event, created_at: 1.hour.ago)

      holder.destroy!
      promoted = described_class.call(event)

      expect(promoted.size).to eq(1)
      expect(promoted.first.user_id).to eq(first.user_id)
      expect(second.reload.status).to eq("waiting")
    end

    it "promotes more than one entry when more than one spot opened up" do
      event = create(:event, capacity: 2)
      holder_a = create(:registration, event: event)
      holder_b = create(:registration, event: event)
      first  = create(:waitlist_entry, event: event, created_at: 2.hours.ago)
      second = create(:waitlist_entry, event: event, created_at: 1.hour.ago)

      holder_a.destroy!
      holder_b.destroy!
      promoted = described_class.call(event)

      expect(promoted.map(&:user_id)).to contain_exactly(first.user_id, second.user_id)
    end

    it "does nothing when the event is still full" do
      event = create(:event, :full)
      create(:waitlist_entry, event: event)

      expect(described_class.call(event)).to eq([])
    end

    it "sets payment_status to paid for a free event and unpaid for a paid one" do
      free_event = create(:event, capacity: 1, price_cents: 0)
      free_holder = create(:registration, event: free_event)
      create(:waitlist_entry, event: free_event)
      free_holder.destroy!

      promoted = described_class.call(free_event).first
      expect(promoted.payment_status).to eq("paid")

      paid_event = create(:event, :paid, capacity: 1)
      paid_holder = create(:registration, event: paid_event)
      create(:waitlist_entry, event: paid_event)
      paid_holder.destroy!

      promoted_paid = described_class.call(paid_event).first
      expect(promoted_paid.payment_status).to eq("unpaid")
    end

    it "snapshots amount_owed_cents on the promoted registration (Ticket B)" do
      paid_event = create(:event, :paid, price_cents: 2500, capacity: 1)
      holder = create(:registration, event: paid_event)
      create(:waitlist_entry, event: paid_event)
      holder.destroy!

      promoted = described_class.call(paid_event).first

      expect(promoted.amount_owed_cents).to eq(2500)
    end

    it "wires up the entry's requested event types on the new registration" do
      event = create(:event, capacity: 10)
      type = event.event_types.create!(name: "5K", capacity: 1, position: 0)
      holder = create(:registration, event: event)
      holder.registration_event_types.create!(event_type: type)
      waiter = create(:waitlist_entry, event: event, event_type_ids: [ type.id ])

      holder.destroy!
      promoted = described_class.call(event).first

      expect(promoted.event_types).to contain_exactly(type)
    end

    it "does not promote an entry whose specifically requested type is still full" do
      event = create(:event, capacity: 10)
      type_a = event.event_types.create!(name: "5K", capacity: 1, position: 0)
      type_b = event.event_types.create!(name: "10K", capacity: 1, position: 1)
      holder_a = create(:registration, event: event)
      holder_a.registration_event_types.create!(event_type: type_a)
      holder_b = create(:registration, event: event)
      holder_b.registration_event_types.create!(event_type: type_b)
      waiter_for_b = create(:waitlist_entry, event: event, event_type_ids: [ type_b.id ])

      holder_a.destroy! # frees type_a only — waiter_for_b wants type_b, still full
      promoted = described_class.call(event)

      expect(promoted).to eq([])
      expect(waiter_for_b.reload.status).to eq("waiting")
    end

    it "sends the promoted-from-waitlist email" do
      event = create(:event, capacity: 1)
      holder = create(:registration, event: event)
      create(:waitlist_entry, event: event)
      holder.destroy!

      expect {
        perform_enqueued_jobs { described_class.call(event) }
      }.to change { ActionMailer::Base.deliveries.count }.by(1)
      expect(ActionMailer::Base.deliveries.last.subject).to include("A spot opened up")
    end
  end
end
