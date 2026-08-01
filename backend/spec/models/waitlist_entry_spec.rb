require "rails_helper"

RSpec.describe WaitlistEntry, type: :model do
  # ── Associations ─────────────────────────────────────────────────────────────
  describe "associations" do
    subject(:entry) { build(:waitlist_entry, event: create(:event, :full)) }

    it { is_expected.to belong_to(:event) }
    it { is_expected.to belong_to(:user) }
  end

  # ── Validations ──────────────────────────────────────────────────────────────
  describe "validations" do
    it "rejects an invalid status" do
      entry = build(:waitlist_entry, event: create(:event, :full), status: "pending")
      expect(entry).not_to be_valid
      expect(entry.errors[:status]).to be_present
    end

    it "prevents a second active waitlist entry for the same user and event" do
      event = create(:event, :full)
      create(:waitlist_entry, event: event, status: "waiting")
      duplicate = build(:waitlist_entry, event: event, status: "waiting")
      # Same user as the first entry — need to share the user, not just the event.
      duplicate.user = WaitlistEntry.find_by(event: event).user
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:user_id]).to be_present
    end

    it "allows a user to rejoin after their earlier entry is no longer waiting" do
      event = create(:event, :full)
      user = create(:user)
      create(:waitlist_entry, :cancelled, event: event, user: user)
      rejoin = build(:waitlist_entry, event: event, user: user)
      expect(rejoin).to be_valid
    end

    it "rejects joining if the user is already registered for the event" do
      event = create(:event, :full)
      registration = event.registrations.first
      entry = build(:waitlist_entry, event: event, user: registration.user)
      expect(entry).not_to be_valid
      expect(entry.errors[:base]).to include("You're already registered for this event")
    end

    it "rejects joining when the event and every requested type still have room" do
      event = create(:event, capacity: 10)
      entry = build(:waitlist_entry, event: event)
      expect(entry).not_to be_valid
      expect(entry.errors[:base]).to include("This event isn't full yet — register normally instead")
    end

    it "allows joining when the event itself is full" do
      event = create(:event, :full)
      entry = build(:waitlist_entry, event: event)
      expect(entry).to be_valid
    end

    it "allows joining when the event has room but a specifically requested type is full" do
      event = create(:event, capacity: 10)
      full_type = event.event_types.create!(name: "5K", capacity: 1, position: 0)
      create(:registration, event: event).registration_event_types.create!(event_type: full_type)

      entry = build(:waitlist_entry, event: event, event_type_ids: [ full_type.id ])
      expect(entry).to be_valid
    end

    it "rejects joining for a type that still has room, even if the event overall is full elsewhere" do
      event = create(:event, capacity: 10)
      open_type = event.event_types.create!(name: "10K", capacity: 5, position: 0)

      entry = build(:waitlist_entry, event: event, event_type_ids: [ open_type.id ])
      expect(entry).not_to be_valid
    end
  end

  # ── Scopes ───────────────────────────────────────────────────────────────────
  describe ".waiting" do
    it "excludes promoted and cancelled entries" do
      event = create(:event, :full)
      waiting   = create(:waitlist_entry, event: event)
      promoted  = create(:waitlist_entry, :promoted, event: event)
      cancelled = create(:waitlist_entry, :cancelled, event: event)

      expect(WaitlistEntry.waiting).to include(waiting)
      expect(WaitlistEntry.waiting).not_to include(promoted, cancelled)
    end
  end
end
