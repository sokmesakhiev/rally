class AddDeletedAtToUsers < ActiveRecord::Migration[8.1]
  # Self-service account deletion (see User#discard!) — deliberately its own
  # column rather than reusing suspended_at, which stays admin-only,
  # reversible, and keeps the account's real PII intact. This one marks an
  # account whose PII has already been scrubbed and can never sign back in
  # under its old identity.
  def change
    add_column :users, :deleted_at, :datetime
    add_index :users, :deleted_at, where: "deleted_at IS NOT NULL"
  end
end
