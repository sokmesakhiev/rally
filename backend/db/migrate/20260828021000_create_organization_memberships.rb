class CreateOrganizationMemberships < ActiveRecord::Migration[8.1]
  # Who else — besides the owner — can act on behalf of an organization.
  #
  # Holds "admin" and "member" ONLY. The owner is organizations.owner_id, not
  # a row here (see the previous migration), so there's no way to end up with
  # two owners or none. Member-listing endpoints union the owner with these
  # rows so the team still reads as one list.
  #
  # Deliberately distinct from event_memberships, which answers a different
  # question: org membership is "can you act for this organization", event
  # membership is "can you help run this specific event". A volunteer gets an
  # event_membership with role check_in on one race and no organization
  # membership at all. Merging them would force every org-level authorization
  # query to reason about event scoping it doesn't care about.
  def change
    create_table :organization_memberships, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :organization_id, null: false
      t.uuid :user_id, null: false
      t.string :role, null: false
      # Nullable for the same reason event_memberships.invited_by_id is: the
      # inviting account may later be anonymized by User#discard!, and losing
      # that provenance shouldn't take the membership with it.
      t.uuid :invited_by_id
      t.timestamps
    end

    # One membership per person per organization — the model mirrors this so
    # the failure surfaces as a validation error rather than a 500.
    add_index :organization_memberships, [ :organization_id, :user_id ], unique: true
    add_index :organization_memberships, :user_id
    add_index :organization_memberships, :role

    add_foreign_key :organization_memberships, :organizations
    add_foreign_key :organization_memberships, :users
    add_foreign_key :organization_memberships, :users, column: :invited_by_id
  end
end
