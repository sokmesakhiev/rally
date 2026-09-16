require "rails_helper"

RSpec.describe CancelWaitlistsForClosedEventsJob, type: :job do
  # WaitlistEntry validates `event_or_requested_types_actually_full` **and**
  # `registration_is_open`, both on create. So a usable fixture has to fill the
  # event first and close it last — which is also the only sequence that
  # happens for real, since nobody queues for an event that has spots or has
  # already closed.
  def full_open_event_with_waiting_entry
    event = create(:event, capacity: 1)
    create(:registration, event: event)
    create(:waitlist_entry, event: event, status: "waiting")
    event
  end

  def closed_event_with_waiting_entry
    full_open_event_with_waiting_entry.tap(&:close_registration!)
  end

  # The reason this job exists. A manual close cancels inline from the
  # controller, but registration_closes_at is evaluated rather than stored, so
  # nothing runs when a deadline passes — the queue would sit waiting for a
  # promotion that can never happen.
  it "ends the waitlist for an event closed by a passed deadline" do
    event = full_open_event_with_waiting_entry
    event.update!(registration_closes_at: 1.hour.ago)

    described_class.perform_now

    expect(event.waitlist_entries.waiting).to be_empty
  end

  it "ends the waitlist for a manually closed event the inline call missed" do
    event = closed_event_with_waiting_entry

    described_class.perform_now

    expect(event.waitlist_entries.waiting).to be_empty
  end

  it "leaves open events alone" do
    entry = full_open_event_with_waiting_entry.waitlist_entries.first

    described_class.perform_now

    expect(entry.reload.status).to eq("waiting")
  end

  it "leaves a future deadline alone" do
    event = full_open_event_with_waiting_entry
    event.update!(registration_closes_at: 2.days.from_now)

    described_class.perform_now

    expect(event.waitlist_entries.first.reload.status).to eq("waiting")
  end

  it "skips soft-deleted events" do
    event = closed_event_with_waiting_entry
    entry = event.waitlist_entries.first
    event.update_columns(deleted_at: Time.current)

    described_class.perform_now

    expect(entry.reload.status).to eq("waiting")
  end

  # The job expresses "closed" in SQL rather than calling the model predicate
  # per row. Two definitions of the same thing in two languages drift, so this
  # pins them against each other across the cases that distinguish them.
  describe "its SQL definition of closed agrees with Event#registration_closed?" do
    [
      [ "manually closed",    -> { { registration_closed_at: Time.current } },      true ],
      [ "deadline passed",    -> { { registration_closes_at: 1.minute.ago } },      true ],
      [ "deadline in future", -> { { registration_closes_at: 1.minute.from_now } }, false ],
      [ "neither set",        -> { {} },                                           false ]
    ].each do |label, attrs, expected_closed|
      it "agrees for an event that is #{label}" do
        # The closure is applied *after* the entry exists, not passed to the
        # factory: WaitlistEntry validates registration_is_open on create, so
        # building a closed event first makes the fixture itself unbuildable.
        event = full_open_event_with_waiting_entry
        changes = attrs.call
        event.update!(changes) if changes.any?

        expect(event.registration_closed?).to eq(expected_closed)

        described_class.perform_now

        swept = event.waitlist_entries.waiting.empty?
        expect(swept).to eq(expected_closed)
      end
    end
  end
end
