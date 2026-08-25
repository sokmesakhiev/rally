# Organizer verification — distinct from email verification
# (email_verified_at), which is self-service and therefore no fraud signal at
# all: anyone with a working inbox passes it. This one is admin-granted only
# (Api::V1::Admin::UsersController#verify) and gates creating *paid* events,
# so money can only be collected by an organizer a human has vetted.
#
# verified_by_id records which admin granted it, so the audit trail survives
# even if the AdminAction row is ever pruned. Nullable and un-foreign-keyed on
# purpose for rows verified before this column existed (there are none today,
# but backfills and console-granted verifications shouldn't be forced to
# invent an actor).
class AddVerifiedAtToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :verified_at, :datetime
    add_column :users, :verified_by_id, :uuid

    # Partial — the gate only ever asks "is this user verified", and verified
    # accounts are the minority, so indexing only those keeps it small.
    add_index :users, :verified_at, where: "(verified_at IS NOT NULL)"
  end
end
