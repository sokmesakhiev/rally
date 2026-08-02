class CreateWaitlistEntries < ActiveRecord::Migration[8.1]
  def change
    create_table :waitlist_entries, id: :uuid do |t|
      t.references :event, null: false, foreign_key: true, type: :uuid, index: true
      t.references :user,  null: false, foreign_key: true, type: :uuid, index: true

      # Which event types the participant wanted, mirroring the
      # event_type_ids a normal registration would have used — nil/empty
      # means "the event itself" (no types, or none picked). jsonb rather
      # than a join table, same pattern as RegistrationAnswer#answer_options:
      # this is intent captured at join-time, not a strong relation the way
      # an actual Registration's RegistrationEventTypes are.
      t.jsonb :event_type_ids, null: false, default: []

      # waiting   — in line, not yet promoted
      # promoted  — Waitlists::PromoteNext converted this into a real
      #             Registration when a spot opened up
      # cancelled — the participant left the waitlist voluntarily
      t.string :status, null: false, default: "waiting"

      t.timestamps
    end

    # A user can only have one *active* waitlist spot per event — but should
    # be able to rejoin later (e.g. after cancelling their spot in line) once
    # that row is no longer "waiting", so this is a partial index rather than
    # a blanket unique constraint on (event_id, user_id).
    add_index :waitlist_entries, [ :event_id, :user_id ],
      unique: true,
      where: "status = 'waiting'",
      name: "index_waitlist_entries_on_event_and_user_when_waiting"

    # FIFO promotion order within an event.
    add_index :waitlist_entries, [ :event_id, :created_at ],
      name: "index_waitlist_entries_on_event_and_created_at"
  end
end
