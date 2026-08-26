class CreateEventInvitations < ActiveRecord::Migration[8.1]
  # A pending invitation to help run an event — see EventInvitation, and
  # the companion event_memberships table (previous migration) for why the
  # two are separate.
  #
  # Addressed to an `email`, not a user_id, precisely because most people
  # invited to help run a gathering won't have a Rally account yet. The
  # recipient signs up or signs in via the tokenized link, and only then
  # does an event_memberships row appear.
  def change
    create_table :event_invitations, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :event_id, null: false
      t.string :email, null: false
      t.string :role, null: false
      t.uuid :invited_by_id, null: false
      t.string :token, null: false
      t.datetime :expires_at, null: false
      t.datetime :accepted_at
      t.datetime :revoked_at
      t.timestamps
    end

    add_index :event_invitations, :token, unique: true
    add_index :event_invitations, :event_id
    add_index :event_invitations, :email

    # Partial unique index: only ONE live invitation per email per event, but
    # any number of historical ones. Without the WHERE clause, revoking an
    # invite and re-sending it to the same person would collide — and the
    # accepted/revoked rows are worth keeping as a record of who was asked.
    add_index :event_invitations, [ :event_id, :email ],
      unique: true,
      where: "(accepted_at IS NULL AND revoked_at IS NULL)",
      name: "index_event_invitations_on_event_and_email_pending"

    add_foreign_key :event_invitations, :events
    add_foreign_key :event_invitations, :users, column: :invited_by_id
  end
end
