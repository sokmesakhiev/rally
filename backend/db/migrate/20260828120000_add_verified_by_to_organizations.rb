class AddVerifiedByToOrganizations < ActiveRecord::Migration[8.1]
  # Mirrors users.verified_by_id — see organization-identity-tickets.md's
  # Ticket I (#338), which moves the paid-event gate off User#verified?.
  # Verification is a claim about who is taking the money, and since #332
  # that's the organization presenting the event, not whichever colleague
  # happened to create it.
  #
  # AdminAction already records who verified what, but that's an append-only
  # log you have to go searching in; this column answers "who vouched for this
  # organization" directly off the row, the same way it does for a user.
  def change
    add_column :organizations, :verified_by_id, :uuid
    add_index :organizations, :verified_at, where: "verified_at IS NOT NULL"

    add_foreign_key :organizations, :users, column: :verified_by_id
  end
end
