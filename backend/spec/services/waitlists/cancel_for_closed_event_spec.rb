require "rails_helper"

RSpec.describe Waitlists::CancelForClosedEvent do
  include ActiveJob::TestHelper

  let(:event) { create(:event, capacity: 1) }

  # WaitlistEntry validates `event_or_requested_types_actually_full` on create —
  # you can't queue for an event with spots left, you just register. So every
  # example needs the event genuinely full before any entry exists.
  let!(:holder) { create(:registration, event: event) }

  # Order matters throughout this file: entries must be created while
  # registration is still open (WaitlistEntry validates that on create too),
  # and the event closed afterwards. That's also the real sequence — nobody
  # joins a waitlist for an event that is already closed.
  def waiting_entry(user: create(:user))
    create(:waitlist_entry, event: event, user: user, status: "waiting")
  end

  describe "the bug this exists for" do
    # Promotion creates a Registration, and Registration validates
    # registration_is_open on create — so on a closed event every promotion
    # raised RecordInvalid, which PromoteNext swallowed as a capacity race.
    # The entry stayed "waiting" forever with nothing logged and nobody told.
    # This is the regression test for that shape, asserted against the two
    # services together rather than either one alone.
    it "leaves nobody waiting on a closed event" do
      waiting_entry
      waiting_entry
      event.close_registration!
      # Free the spot, so PromoteNext below has something to promote *into*.
      # Without this the event is still full and it would return empty for the
      # uninteresting reason, which would pass whether or not the bug existed.
      holder.destroy!

      described_class.call(event)

      expect(event.waitlist_entries.waiting).to be_empty
      expect(Waitlists::PromoteNext.call(event)).to be_empty
    end
  end

  describe "cancelling" do
    it "cancels every waiting entry and reports how many" do
      waiting_entry
      waiting_entry
      event.close_registration!

      expect(described_class.call(event).cancelled).to eq(2)
      expect(event.waitlist_entries.reload.pluck(:status).uniq).to eq([ "cancelled" ])
    end

    it "does nothing at all while the event is still open" do
      entry = waiting_entry

      expect(described_class.call(event).cancelled).to eq(0)
      expect(entry.reload.status).to eq("waiting")
    end

    it "leaves already-promoted entries alone" do
      promoted = create(:waitlist_entry, event: event, status: "promoted")
      event.close_registration!

      described_class.call(event)

      expect(promoted.reload.status).to eq("promoted")
    end

    # A discarded event's queue should hear nothing — the event is gone, not
    # closed, and Event#discard! has already cancelled these rows.
    it "skips entries discarded along with their event" do
      entry = waiting_entry
      entry.discard!
      event.close_registration!

      expect(described_class.call(event).cancelled).to eq(0)
    end

    # The sweep runs hourly and the controller runs it inline, so the same
    # closed event is processed repeatedly. Nobody should be told twice.
    it "is idempotent" do
      waiting_entry
      event.close_registration!

      described_class.call(event)

      expect { described_class.call(event) }.not_to change(Notification, :count)
    end
  end

  # The deadline path is the half with no moment to hook: registration_closes_at
  # is evaluated, never stored, so nothing runs when it passes.
  describe "a passed deadline" do
    it "counts as closed" do
      waiting_entry
      event.update!(registration_closes_at: 1.hour.ago)

      expect(described_class.call(event).cancelled).to eq(1)
    end

    it "does not count while the deadline is still in the future" do
      waiting_entry
      event.update!(registration_closes_at: 1.day.from_now)

      expect(described_class.call(event).cancelled).to eq(0)
    end
  end

  describe "notifying" do
    it "writes one in-app notification per cancelled entry" do
      entry = waiting_entry
      event.close_registration!

      expect { described_class.call(event) }.to change(Notification, :count).by(1)

      notification = Notification.last
      expect(notification.kind).to eq("waitlist_closed")
      expect(notification.user_id).to eq(entry.user_id)
      expect(notification.body).to include(event.title)
    end

    it "pushes to someone who hasn't muted waitlist notifications" do
      entry = waiting_entry
      event.close_registration!

      expect { described_class.call(event) }
        .to have_enqueued_job(SendPushNotificationJob).with(entry.user_id, any_args)
    end

    # The codebase's rule, not this service's choice: push respects notify_*,
    # the bell row is always written. Someone who muted waitlist pushes still
    # needs a way to find out the event closed.
    it "still writes the bell row for someone who muted the push" do
      entry = waiting_entry
      entry.user.profile.update!(notify_promoted_from_waitlist: false)
      event.close_registration!

      expect { described_class.call(event) }.to change(Notification, :count).by(1)
      expect(enqueued_jobs.select { |j| j[:job] == SendPushNotificationJob }).to be_empty
    end
  end

  describe "when one entry fails" do
    # The failure this whole service exists to fix is people left waiting
    # silently. An exception halfway through the list would recreate it for
    # everyone after that point.
    it "still cancels the rest of the queue" do
      first = waiting_entry
      second = waiting_entry
      event.close_registration!

      allow(Notifications::WaitlistNotifier)
        .to receive(:registration_closed).and_wrap_original do |original, entry|
          raise "boom" if entry.id == first.id

          original.call(entry)
        end

      expect(described_class.call(event).cancelled).to eq(1)
      expect(second.reload.status).to eq("cancelled")
      expect(first.reload.status).to eq("waiting")
    end
  end
end
