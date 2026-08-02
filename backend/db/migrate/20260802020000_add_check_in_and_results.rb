class AddCheckInAndResults < ActiveRecord::Migration[8.1]
  def change
    # Attendance: nil until an organizer scans/taps the participant in on
    # event day. A timestamp (not a boolean) so "when" is available for free
    # (e.g. a future arrivals-over-time chart) without another column.
    add_column :registrations, :checked_in_at, :datetime

    # One optional finish-time result per registration — race events use
    # this, a social gathering just never gets one. Stored as an integer
    # count of seconds (not a string like "1:23:45") so sorting/leaderboard
    # queries and CSV import don't need to parse a duration format at read
    # time; formatting to/from "HH:MM:SS" happens at the edges (frontend,
    # CSV import parsing) instead.
    create_table :results, id: :uuid do |t|
      t.references :registration, null: false, foreign_key: true, type: :uuid, index: { unique: true }
      t.integer :finish_time_seconds
      t.string :notes
      t.timestamps
    end
  end
end
