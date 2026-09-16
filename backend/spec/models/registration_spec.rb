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

  describe "bib_number" do
    let(:event) { create(:event) }

    it "is unique within an event" do
      create(:registration, event: event, bib_number: "A1042")
      duplicate = build(:registration, event: event, bib_number: "A1042")

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:bib_number]).to include("is already taken for this event")
    end

    it "lets two different events reuse the same number" do
      create(:registration, event: event, bib_number: "101")
      other = build(:registration, event: create(:event), bib_number: "101")

      expect(other).to be_valid
    end

    # The partial unique index keys on `bib_number IS NOT NULL`, so an empty
    # string would be a real value — the second participant to have their bib
    # cleared would collide with the first.
    it "stores blank as nil so many participants can be unassigned" do
      first  = create(:registration, event: event, bib_number: "  ")
      second = create(:registration, event: event, bib_number: "")

      expect(first.bib_number).to be_nil
      expect(second).to be_valid
      expect(event.registrations.where(bib_number: nil).count).to eq(2)
    end

    it "strips surrounding whitespace" do
      registration = create(:registration, event: event, bib_number: "  A7  ")

      expect(registration.bib_number).to eq("A7")
    end

    # A string, not an integer: leading zeros are printed on the physical bib.
    it "preserves leading zeros" do
      expect(create(:registration, event: event, bib_number: "0007").bib_number).to eq("0007")
    end

    # Deliberately not scoped to kept rows, unlike the user_id uniqueness rule.
    # Reissuing a withdrawn runner's number would orphan their result and
    # certificate, which still reference it.
    it "keeps a discarded participant's number reserved" do
      create(:registration, event: event, bib_number: "500").discard!
      reuse = build(:registration, event: event, bib_number: "500")

      expect(reuse).not_to be_valid
    end
  end

  describe ".search" do
    let(:event) { create(:event) }

    it "finds a participant by bib number" do
      match = create(:registration, event: event, bib_number: "A1042")
      create(:registration, event: event, bib_number: "B7")

      expect(event.registrations.search("a1042")).to contain_exactly(match)
    end

    # The check-in desk is the reason: someone arrives holding a bib, and the
    # volunteer types what's printed on it.
    it "matches a partial bib" do
      match = create(:registration, event: event, bib_number: "A1042")

      expect(event.registrations.search("104")).to contain_exactly(match)
    end

    it "still matches on name and email" do
      user = create(:user, email: "find.me@example.com")
      user.profile.update!(display_name: "Sokmesa Khiev")
      match = create(:registration, event: event, user: user)
      create(:registration, event: event)

      expect(event.registrations.search("sokmesa")).to contain_exactly(match)
      expect(event.registrations.search("find.me")).to contain_exactly(match)
    end
  end
end
