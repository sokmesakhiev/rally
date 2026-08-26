class CreateEventMemberships < ActiveRecord::Migration[8.1]
  # An accepted, live grant of access to someone other than the event's
  # creator — see EventMembership. Deliberately a separate table from
  # event_invitations (next migration): an invitation is a message with its
  # own lifecycle addressed to an email that may never become a user, while
  # this is a grant tied to a real account. Keeping them apart is what lets
  # the unique index below be a plain two-column one; a combined table would
  # need every authorization query to filter out not-yet-accepted rows
  # forever.
  #
  # accepted_at is null: false because a row only exists once someone has
  # actually accepted — "pending" lives on event_invitations, not here.
  def change
    create_table :event_memberships, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :event_id, null: false
      t.uuid :user_id, null: false
      t.string :role, null: false
      # Nullable: the inviting account may later be deleted (User#discard!
      # anonymizes rather than destroys, but a console-granted membership
      # has no inviter at all), and losing that provenance shouldn't take
      # the membership with it.
      t.uuid :invited_by_id
      t.datetime :accepted_at, null: false
      t.timestamps
    end

    # One membership per person per event — the model mirrors this so the
    # failure surfaces as a validation error rather than a 500.
    add_index :event_memberships, [ :event_id, :user_id ], unique: true
    add_index :event_memberships, :user_id
    add_index :event_memberships, :role

    add_foreign_key :event_memberships, :events
    add_foreign_key :event_memberships, :users
    add_foreign_key :event_memberships, :users, column: :invited_by_id
  end
end
