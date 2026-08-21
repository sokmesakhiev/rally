class AddAmountOwedCentsToRegistrations < ActiveRecord::Migration[8.1]
  def change
    # Snapshot of what this registration owed at creation time, computed
    # from the event/event-type price(s) in effect then (see
    # Api::V1::RegistrationsController#compute_amount and
    # Waitlists::PromoteNext#compute_amount) — kept fixed even if the
    # organizer changes the price later while the registration is still
    # unpaid. See change-event-plan-tickets.md's "Ticket B" for the bug
    # this fixes (the previous behavior, Registration#owed_amount_cents
    # recomputing live from the *current* price, silently changed what an
    # outstanding payment attempt charged).
    #
    # Nullable on purpose: existing rows predate this snapshot and have no
    # value to backfill from (the price at the time they were created isn't
    # recorded anywhere) — Registration#owed_amount_cents falls back to the
    # old live-recompute for those. Every row created from here on always
    # gets a value.
    add_column :registrations, :amount_owed_cents, :integer
  end
end
