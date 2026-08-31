class CreateOrganizations < ActiveRecord::Migration[8.1]
  # The public identity an event is presented under — see Organization and
  # organization-identity-tickets.md's Ticket A. Events belong to one of
  # these rather than directly to the User who created them, so a club with
  # several staff shares one brand and one person can run several brands.
  #
  # owner_id is a plain column rather than an "owner" role on
  # organization_memberships (next migration). That makes "exactly one owner"
  # a structural guarantee instead of an invariant some validation has to
  # defend, and it gives the suspension cascade (Ticket J) a two-hop
  # belongs_to chain (event -> organization -> owner) that can be preloaded,
  # rather than a join through membership rows on a hot authorization path.
  def change
    create_table :organizations, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :owner_id, null: false
      t.string :name, null: false
      # Immutable after create — see Organization#slug_is_immutable. A public
      # URL that changes silently breaks every link the organizer has already
      # shared, so renaming updates :name and never this.
      t.string :slug, null: false
      t.text :description

      # Branding. Deliberately parallel to Event's own banner_url/logo_url/
      # brand_color rather than replacing them: per the up-front scoping
      # decision, org branding and event branding are both shown, in
      # different places, with no inheritance and no override.
      t.string :logo_url
      t.string :banner_url
      t.string :brand_color

      # Public-facing contact details. contact_email is NOT the account's
      # login email (that lives on users) — an organizer publishes a support
      # address without exposing the one they sign in with.
      t.string :website
      t.string :contact_email
      t.string :contact_phone
      t.string :facebook_url
      t.string :instagram_url
      t.string :telegram_url

      # Set by Ticket I, which moves the paid-event gate off User#verified?.
      # Nullable and unused until then.
      t.datetime :verified_at

      # Admin moderation (Ticket J). Suspension cascades *downward by
      # derivation*: Event#suspended? consults its organization, and
      # Organization#suspended? consults its owner — nothing is written
      # downward, so unsuspending restores exactly what the cascade took
      # down and can never drift out of sync.
      t.datetime :suspended_at
      t.string :suspension_reason

      # Soft-delete, matching the explicit-scopes (not default_scope) pattern
      # Event/Registration/Survey/User already use.
      t.datetime :deleted_at

      t.timestamps
    end

    add_index :organizations, :slug, unique: true
    add_index :organizations, :owner_id
    add_index :organizations, :deleted_at
    add_index :organizations, :suspended_at, where: "suspended_at IS NOT NULL"

    add_foreign_key :organizations, :users, column: :owner_id
  end
end
