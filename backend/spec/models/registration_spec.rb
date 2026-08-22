require "rails_helper"

RSpec.describe Registration, type: :model do
  # ── #owed_amount_cents ────────────────────────────────────────────────────
  # See change-event-plan-tickets.md's "Ticket B": amount_owed_cents is a
  # snapshot taken once at creation time (RegistrationsController#create,
  # Waitlists::PromoteNext#promote!) so a still-unpaid registration keeps
  # owing what it owed when the participant registered, even if the
  # organizer changes the price afterward.
  describe "#owed_amount_cents" do
    let(:event) { create(:event, :paid, price_cents: 2500) }

    it "returns the snapshot when amount_owed_cents was set at creation" do
      registration = create(:registration, event: event, amount_owed_cents: 2500)

      event.update!(price_cents: 5000)

      expect(registration.reload.owed_amount_cents).to eq(2500)
    end

    it "stays fixed even after the price changes while still unpaid" do
      registration = create(:registration, event: event, payment_status: "unpaid", amount_owed_cents: 2500)

      event.update!(price_cents: 9900)

      expect(registration.owed_amount_cents).to eq(2500)
    end

    it "falls back to a live recompute from the event price for rows with no snapshot (legacy data)" do
      registration = create(:registration, event: event, amount_owed_cents: nil)

      expect(registration.owed_amount_cents).to eq(2500)

      event.update!(price_cents: 4000)

      expect(registration.owed_amount_cents).to eq(4000)
    end

    it "falls back to summing selected event types' effective price when there's no snapshot" do
      type_a = event.event_types.create!(name: "5K", price_cents: 1000, position: 0)
      type_b = event.event_types.create!(name: "10K", position: 1) # no override — falls back to event price
      registration = create(:registration, event: event, amount_owed_cents: nil)
      registration.registration_event_types.create!(event_type: type_a)
      registration.registration_event_types.create!(event_type: type_b)

      expect(registration.owed_amount_cents).to eq(1000 + 2500)
    end
  end
end
