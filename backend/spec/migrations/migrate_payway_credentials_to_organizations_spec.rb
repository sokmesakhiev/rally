require "rails_helper"
require Rails.root.join("db/migrate/20260828061000_migrate_payway_credentials_to_organizations")

# Moves each organizer's connected PayWay account from their Profile onto the
# Organization that presents their events. Worth specc'ing carefully: get this
# wrong and registration money either stops reaching organizers (credentials
# lost, everything falls back to Rally's platform account) or reaches the
# wrong one.
#
# Profile's payway_* columns are ignored_columns on the model since #331, so
# these specs write and read the pre-migration state through raw SQL — which
# is also a truer simulation of what the migration actually finds.
RSpec.describe MigratePaywayCredentialsToOrganizations do
  subject(:run_migration) do
    ActiveRecord::Migration.suppress_messages { described_class.new.up }
  end

  # Mirrors the encryption the real Profile used before #331, so the migration
  # decrypts exactly what it would in production.
  let(:legacy_profile_class) do
    Class.new(ActiveRecord::Base) do
      self.table_name = "profiles"
      encrypts :payway_api_key
    end
  end

  def connect_payway_on_profile(user, merchant_id:, api_key:, rsa_public_key: nil)
    legacy_profile_class.find_by(user_id: user.id).update!(
      payway_merchant_id: merchant_id,
      payway_api_key: api_key,
      payway_rsa_public_key: rsa_public_key
    )
  end

  it "copies credentials onto the organizer's organization" do
    organizer = create(:user)
    organization = create(:organization, owner: organizer)
    connect_payway_on_profile(organizer, merchant_id: "m_123", api_key: "secret_abcdef1234")

    run_migration

    expect(organization.reload.payway_merchant_id).to eq("m_123")
    expect(organization.payway_api_key).to eq("secret_abcdef1234")
  end

  # The key is encrypted on both sides; a ciphertext-level copy could leave it
  # undecryptable, which is why the migration round-trips through the models.
  it "leaves the api key decryptable, and still encrypted at rest" do
    organizer = create(:user)
    organization = create(:organization, owner: organizer)
    connect_payway_on_profile(organizer, merchant_id: "m_123", api_key: "secret_abcdef1234")

    run_migration

    raw = Organization.connection.select_value(
      "SELECT payway_api_key FROM organizations WHERE id = #{Organization.connection.quote(organization.id)}"
    )
    expect(raw).not_to include("secret_abcdef1234")
    expect(organization.reload.payway_api_key).to eq("secret_abcdef1234")
  end

  it "carries the RSA public key across too" do
    organizer = create(:user)
    organization = create(:organization, owner: organizer)
    connect_payway_on_profile(
      organizer, merchant_id: "m_123", api_key: "k", rsa_public_key: "-----BEGIN PUBLIC KEY-----"
    )

    run_migration

    expect(organization.reload.payway_rsa_public_key).to eq("-----BEGIN PUBLIC KEY-----")
  end

  it "ignores organizers who never connected PayWay" do
    organizer = create(:user)
    organization = create(:organization, owner: organizer)

    run_migration

    expect(organization.reload.payway_merchant_id).to be_nil
  end

  # A user may own several organizations by now. The one their existing events
  # are presented by is the oldest — the one #330's backfill created.
  it "targets the oldest owned organization when there are several" do
    organizer = create(:user)
    oldest = create(:organization, owner: organizer, created_at: 3.days.ago)
    newer = create(:organization, owner: organizer, created_at: 1.day.ago)
    connect_payway_on_profile(organizer, merchant_id: "m_123", api_key: "k")

    run_migration

    expect(oldest.reload.payway_merchant_id).to eq("m_123")
    expect(newer.reload.payway_merchant_id).to be_nil
  end

  it "does nothing for a user who has no organization at all" do
    organizer = create(:user)
    connect_payway_on_profile(organizer, merchant_id: "m_123", api_key: "k")

    expect { run_migration }.not_to raise_error
    expect(Organization.where(owner_id: organizer.id)).to be_empty
  end

  it "never touches another organizer's organization" do
    organizer = create(:user)
    create(:organization, owner: organizer)
    connect_payway_on_profile(organizer, merchant_id: "m_123", api_key: "k")
    someone_else = create(:organization)

    run_migration

    expect(someone_else.reload.payway_merchant_id).to be_nil
  end

  # Re-running must not clobber credentials an organizer has since changed at
  # the organization level.
  it "is idempotent and does not overwrite newer organization credentials" do
    organizer = create(:user)
    organization = create(:organization, owner: organizer)
    connect_payway_on_profile(organizer, merchant_id: "old_merchant", api_key: "old_key")
    run_migration

    organization.update!(payway_merchant_id: "new_merchant", payway_api_key: "new_key")
    ActiveRecord::Migration.suppress_messages { described_class.new.up }

    expect(organization.reload.payway_merchant_id).to eq("new_merchant")
    expect(organization.payway_api_key).to eq("new_key")
  end

  it "is irreversible rather than writing stale credentials back to profiles" do
    expect { described_class.new.down }.to raise_error(ActiveRecord::IrreversibleMigration)
  end
end
