class AddOrganizationToEvents < ActiveRecord::Migration[8.1]
  # Events are presented by an Organization rather than by the individual who
  # created them — see organization-identity-tickets.md's Ticket C (#332).
  #
  # Nullable here; the next migration backfills every existing row and then
  # tightens this to null: false. Splitting it that way keeps each migration
  # doing one thing, and means a backfill failure leaves a recoverable state
  # rather than a half-applied NOT NULL constraint.
  #
  # creator_id deliberately STAYS. It's still meaningful to know which human
  # created an event (the activity log references it, and "who set this up"
  # is a different question from "who is it presented by"), and dropping it
  # would break EventAuthorization's existing owner short-circuit.
  def change
    add_column :events, :organization_id, :uuid
    add_index :events, :organization_id
    add_foreign_key :events, :organizations
  end
end
