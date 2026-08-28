class BackfillOrganizationVerification < ActiveRecord::Migration[8.1]
  # Carries each verified organizer's status onto the organizations they own,
  # so nobody loses the ability to run paid events the moment the gate moves
  # from User#verified? to Organization#verified? (Ticket I, #338).
  #
  # This is the load-bearing half of that ticket. Without it, every currently
  # verified organizer would silently start failing at paid-event creation
  # with "your account needs to be verified" — pointing at an account that
  # already is.
  #
  # Applies to organizations the verified user OWNS. Being an admin of a club
  # doesn't make that club verified: verification is about who receives the
  # money, and that's the owner's PayWay account (see Ticket B, #331).
  def up
    execute(<<~SQL)
      UPDATE organizations
         SET verified_at = users.verified_at,
             verified_by_id = users.verified_by_id,
             updated_at = NOW()
        FROM users
       WHERE users.id = organizations.owner_id
         AND users.verified_at IS NOT NULL
         AND organizations.verified_at IS NULL
    SQL
  end

  # Irreversible by intent: rolling back would strip verification that staff
  # may have granted or revoked at the organization level since. The source
  # data on users is untouched either way — User#verified? and its admin
  # endpoints stay in place for one release (see the model).
  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
