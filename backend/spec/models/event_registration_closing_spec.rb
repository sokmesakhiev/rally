require "rails_helper"

RSpec.describe "Event registration closing", type: :model do
  let(:event) { create(:event, capacity: 100) }

  describe "#registration_closed?" do
    it "is false for an event nobody has closed and with no deadline" do
      expect(event).not_to be_registration_closed
      expect(event).to be_accepting_signups
    end

    it "is true once the organizer closes it" do
      event.close_registration!

      expect(event.reload).to be_registration_closed
      expect(event).not_to be_accepting_signups
    end

    # The deadline is evaluated, not stored as a flag — so it takes effect the
    # moment it passes, with no scheduled job and no window where the flag
    # lags reality. These two pin the boundary.
    it "is false while the deadline is still in the future" do
      event.update!(registration_closes_at: 1.hour.from_now)

      expect(event).not_to be_registration_closed
    end

    it "is true once the deadline has passed, with nothing else changing" do
      event.update!(registration_closes_at: 1.minute.ago)

      expect(event).to be_registration_closed
      expect(event.registration_closed_at).to be_nil
    end

    it "treats the deadline as inclusive at the exact instant" do
      now = Time.current
      event.update!(registration_closes_at: now)

      expect(event.registration_closed?(now)).to be true
    end
  end

  describe "#reopen_registration!" do
    it "clears the manual close" do
      event.close_registration!
      event.reopen_registration!

      expect(event.reload).not_to be_registration_closed
    end

    # Without this the button looks broken: reopen, and a deadline that has
    # already passed re-closes the event on the very next read.
    it "clears a passed deadline too, so reopening actually reopens" do
      event.update!(registration_closes_at: 1.day.ago)
      event.close_registration!

      event.reopen_registration!

      expect(event.reload).not_to be_registration_closed
      expect(event.registration_closes_at).to be_nil
    end
  end

  # Closed and full are deliberately separate — a closed event can have
  # hundreds of free spots, and the two lead to different UI.
  describe "independence from capacity" do
    it "is closed while nowhere near full" do
      event.close_registration!

      expect(event.reload).to be_registration_closed
      expect(event).not_to be_full
    end

    it "is open while full" do
      event.update!(capacity: 1)
      create(:registration, event: event)

      expect(event).to be_full
      expect(event).to be_accepting_signups
    end
  end

  describe "Registration" do
    it "refuses a new registration on a closed event" do
      event.close_registration!

      registration = build(:registration, event: event.reload)

      expect(registration).not_to be_valid
      expect(registration.errors.details[:base]).to include(hash_including(error: :registration_closed))
    end

    it "refuses a new registration once the deadline has passed" do
      event.update!(registration_closes_at: 1.minute.ago)

      expect(build(:registration, event: event)).not_to be_valid
    end

    # The whole point of validating `on: :create`. A paid registration's row is
    # written *before* the KHQR payment succeeds, so if closing blocked every
    # save, the ABA webhook marking someone paid would fail — taking their
    # money and then refusing the spot.
    it "still lets an existing registration be marked paid after closing" do
      registration = create(:registration, event: event, payment_status: "unpaid")
      event.close_registration!

      expect {
        registration.update!(payment_status: "paid", amount_paid_cents: 2500)
      }.not_to raise_error

      expect(registration.reload.payment_status).to eq("paid")
    end
  end

  describe "WaitlistEntry" do
    # A closed event isn't waiting for anything, so collecting names would
    # promise something the organizer has just said they aren't doing.
    it "refuses a new waitlist entry on a closed event" do
      event.update!(capacity: 1)
      create(:registration, event: event)
      event.close_registration!

      entry = build(:waitlist_entry, event: event.reload)

      expect(entry).not_to be_valid
      expect(entry.errors.details[:base]).to include(hash_including(error: :registration_closed))
    end

    it "still allows a waitlist entry while open and full" do
      event.update!(capacity: 1)
      create(:registration, event: event)

      expect(build(:waitlist_entry, event: event)).to be_valid
    end
  end
end
