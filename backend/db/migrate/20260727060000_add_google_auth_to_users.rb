class AddGoogleAuthToUsers < ActiveRecord::Migration[8.1]
  def change
    # provider is currently always "google" or nil, but kept as a free string
    # (rather than an enum) so a future second OAuth provider doesn't need a
    # migration to widen it.
    add_column :users, :provider, :string
    add_column :users, :google_uid, :string

    # Multiple NULLs are allowed under a unique index in Postgres, so
    # password-only accounts (google_uid: nil) don't conflict with each other.
    add_index :users, :google_uid, unique: true
  end
end
