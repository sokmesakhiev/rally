class MigratePaywayCredentialsToOrganizations < ActiveRecord::Migration[8.1]
  # Copies each organizer's connected PayWay account from their personal
  # Profile onto the Organization that presents their events.
  #
  # Local AR classes rather than ::Profile / ::Organization, same as the other
  # backfills — but these DO declare `encrypts`, deliberately. payway_api_key
  # is stored via Active Record encryption, so moving it has to go through
  # decrypt-then-encrypt: a raw SQL ciphertext copy would depend on Rails'
  # internal ciphertext format staying portable between columns, which is not
  # a promise worth betting an organizer's payment credentials on.
  #
  # payway_rsa_public_key is genuinely public (see Profile#payway_refund_configured?)
  # and is not encrypted, hence no declaration for it.
  class MigrationProfile < ActiveRecord::Base
    self.table_name = "profiles"
    encrypts :payway_api_key
  end

  class MigrationOrganization < ActiveRecord::Base
    self.table_name = "organizations"
    encrypts :payway_api_key
  end

  def up
    MigrationProfile.where.not(payway_merchant_id: nil).find_each do |profile|
      organization = target_organization_for(profile.user_id)
      next if organization.nil?
      # Idempotency: re-running must not clobber credentials an organizer has
      # since changed through the new organization-level settings.
      next if organization.payway_merchant_id.present?

      organization.update!(
        payway_merchant_id: profile.payway_merchant_id,
        payway_api_key: profile.payway_api_key,
        payway_rsa_public_key: profile.payway_rsa_public_key
      )
    end
  end

  # Deliberately irreversible. Rolling this back would mean writing payment
  # credentials back onto profiles, and by then an organizer may have changed
  # them at the organization level — the old profile copy is not authoritative
  # any more. The profiles columns are left in place (see the Profile model's
  # ignored_columns), so a rollback of the *code* still finds its data intact.
  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

  # A user may own several organizations, so pick the one their existing
  # events are actually presented by: the oldest, which is the one #330's
  # backfill created. Anything newer was created deliberately afterwards and
  # has no claim on credentials connected before it existed.
  def target_organization_for(user_id)
    MigrationOrganization.where(owner_id: user_id).order(:created_at, :id).first
  end
end
