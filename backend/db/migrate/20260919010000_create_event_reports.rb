# frozen_string_literal: true

# Participant-facing "report this event" intake, feeding the existing admin
# moderation surface (Event#suspend! / #unpublish, logged to admin_actions).
#
# Notice-and-takedown rather than pre-publication screening. The enforcement
# half was already built; only the intake was missing, which is why this is a
# small table rather than a pipeline.
class CreateEventReports < ActiveRecord::Migration[8.1]
  def change
    create_table :event_reports, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :event, null: false, foreign_key: true, type: :uuid

      # Nullable: an anonymous report is allowed on purpose. The person best
      # placed to report a gathering they're frightened of may not want an
      # account attached to it, and requiring one filters out exactly the
      # reports worth having. ON DELETE SET NULL for the same reason
      # messages.sender_id is — a report outlives the reporter's account.
      t.references :reporter, foreign_key: { to_table: :users, on_delete: :nullify },
                              type: :uuid, null: true

      t.string :reason, null: false
      t.text :details

      # open → reviewing → actioned | dismissed. Terminal states are distinct
      # because "we looked and took it down" and "we looked and it's fine" are
      # different facts, and collapsing them would make the queue's history
      # useless for showing a consistent process.
      t.string :status, null: false, default: "open"
      t.references :reviewed_by, foreign_key: { to_table: :users, on_delete: :nullify },
                                 type: :uuid, null: true
      t.datetime :reviewed_at
      t.text :reviewer_note

      t.timestamps
    end

    # The queue's own query: open reports, newest first.
    add_index :event_reports, [ :status, :created_at ]

    # One open report per reporter per event. Stops a single signed-in account
    # inflating an event's report count, which matters because count drives
    # queue priority — without this, priority is trivially forgeable by one
    # person clicking twice. Partial on both axes: anonymous reports have no
    # reporter to deduplicate, and a closed report shouldn't block a genuine
    # new one about a later change to the same event.
    add_index :event_reports, [ :event_id, :reporter_id ],
              unique: true,
              where: "reporter_id IS NOT NULL AND status IN ('open', 'reviewing')",
              name: "index_event_reports_one_open_per_reporter"

    add_check_constraint :event_reports,
                         "reason IN ('political', 'gambling', 'violence', 'discrimination', 'other')",
                         name: "event_reports_reason_valid"
    add_check_constraint :event_reports,
                         "status IN ('open', 'reviewing', 'actioned', 'dismissed')",
                         name: "event_reports_status_valid"
  end
end
