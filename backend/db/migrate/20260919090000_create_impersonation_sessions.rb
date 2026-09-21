# frozen_string_literal: true

# Staff impersonation — see docs/impersonation-design.md.
#
# The row exists for two reasons that a stateless token can't cover: a session
# has to be *revocable* mid-flight (D5), and impersonation has to leave a
# record that outlives the token (D9). The JWT carries this row's id in `sid`
# and every impersonated request re-reads it.
class CreateImpersonationSessions < ActiveRecord::Migration[8.1]
  def change
    create_table :impersonation_sessions, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      # The staff account driving. Not `on_delete: :nullify` like
      # event_reports.reporter: an audit row whose actor has been forgotten is
      # not an audit row, and deleting a staff account is a soft delete
      # (User#discard!) which leaves the row intact anyway.
      t.references :admin, null: false, foreign_key: { to_table: :users }, type: :uuid
      # The account being viewed.
      t.references :user, null: false, foreign_key: true, type: :uuid

      # Required, 10–500 chars, and quoted verbatim to the user in the
      # notification (D7). The cheapest control in the design: writing the
      # reason knowing the person will read it is what makes idle curiosity
      # feel like what it is.
      t.text :reason, null: false

      # Set once at creation and never extended. A longer look means a new
      # session, which means a new audit row and a new notification (D6).
      t.datetime :expires_at, null: false

      # Both nullable, and "live" is *evaluated* from the three columns rather
      # than stored as a flag — same decision as events.registration_closes_at.
      # A flag would need a job flipping rows across the table, plus a window
      # where a session had expired but the flag hadn't caught up.
      t.datetime :ended_at
      t.datetime :revoked_at
      t.references :revoked_by, foreign_key: { to_table: :users, on_delete: :nullify },
                                type: :uuid, null: true

      # Where the session was opened from. Kept for investigations; not shown
      # to the impersonated user.
      t.string :ip
      t.string :user_agent

      t.timestamps
    end

    # One live session per admin. Two simultaneous impersonations by one person
    # is not a workflow, it's a mistake or an attack. Partial index + a
    # matching `conditions:` on the model's uniqueness validation, the same
    # pairing as conversations and registrations — a model that allows what the
    # database rejects is the more confusing half of that bug.
    add_index :impersonation_sessions, :admin_id,
              unique: true,
              where: "ended_at IS NULL AND revoked_at IS NULL",
              name: "index_impersonation_sessions_one_live_per_admin"

    # The user's own "who has accessed my account" history, newest first.
    add_index :impersonation_sessions, [ :user_id, :created_at ]
  end
end
