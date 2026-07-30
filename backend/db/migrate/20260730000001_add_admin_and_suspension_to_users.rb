class AddAdminAndSuspensionToUsers < ActiveRecord::Migration[8.1]
  def change
    # Deliberately a boolean flag rather than a roles table: there are exactly
    # two kinds of actor here (ordinary user, Rally staff), and a join table
    # would be structure without a second use for it. Revisit if per-permission
    # granularity is ever needed.
    add_column :users, :admin, :boolean, default: false, null: false

    # Nullable timestamp rather than a boolean, so we keep *when* a suspension
    # happened — useful for disputes, and lets "unsuspend" be a plain nil
    # without losing that it ever occurred in the logs.
    add_column :users, :suspended_at, :datetime
    add_column :users, :suspension_reason, :string

    # Partial index: only suspended rows are ever looked up this way, and
    # suspended users are (hopefully) a vanishing fraction of the table.
    add_index :users, :suspended_at, where: "suspended_at IS NOT NULL"

    # Supports the admin user list's "admins first" ordering / filtering.
    add_index :users, :admin, where: "admin = true"
  end
end
