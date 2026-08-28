require "rails_helper"
require Rails.root.join("db/migrate/20260828121000_backfill_organization_verification")

# organization-identity-tickets.md's Ticket I (#338). The load-bearing half of
# moving the paid-event gate: without this, every currently verified organizer
# would silently start failing at paid-event creation, told to verify an
# account that already is.
RSpec.describe BackfillOrganizationVerification do
  subject(:run_migration) do
    ActiveRecord::Migration.suppress_messages { described_class.new.up }
  end

  # The factory inherits verification from the creator (mirroring what this
  # migration does), so build the pre-migration state explicitly.
  def unverified_organization_for(user)
    create(:organization, owner: user).tap do |org|
      Organization.where(id: org.id).update_all(verified_at: nil, verified_by_id: nil)
      org.reload
    end
  end

  it "verifies organizations owned by a verified organizer" do
    admin = create(:user, admin: true)
    organizer = create(:user)
    organizer.verify!(by: admin)
    organization = unverified_organization_for(organizer)

    run_migration

    expect(organization.reload.verified?).to be(true)
  end

  it "carries across who verified them" do
    admin = create(:user, admin: true)
    organizer = create(:user)
    organizer.verify!(by: admin)
    organization = unverified_organization_for(organizer)

    run_migration

    expect(organization.reload.verified_by_id).to eq(admin.id)
  end

  it "verifies every organization a verified organizer owns" do
    admin = create(:user, admin: true)
    organizer = create(:user)
    organizer.verify!(by: admin)
    first = unverified_organization_for(organizer)
    second = unverified_organization_for(organizer)

    run_migration

    expect(first.reload.verified?).to be(true)
    expect(second.reload.verified?).to be(true)
  end

  it "leaves organizations owned by an unverified organizer alone" do
    organization = unverified_organization_for(create(:user))

    run_migration

    expect(organization.reload.verified?).to be(false)
  end

  # Verification is about who receives the money — that's the owner's PayWay
  # account, so administering a club doesn't verify it.
  it "does not verify a club the verified user merely administers" do
    admin = create(:user, admin: true)
    organizer = create(:user)
    organizer.verify!(by: admin)
    club = unverified_organization_for(create(:user))
    create(:organization_membership, organization: club, user: organizer, role: "admin")

    run_migration

    expect(club.reload.verified?).to be(false)
  end

  it "does not overwrite an organization verified at a different time" do
    admin = create(:user, admin: true)
    organizer = create(:user)
    organizer.verify!(by: admin)
    organization = create(:organization, owner: organizer)
    already = 10.days.ago.change(usec: 0)
    Organization.where(id: organization.id).update_all(verified_at: already)

    run_migration

    expect(organization.reload.verified_at).to be_within(1.second).of(already)
  end

  it "is idempotent" do
    admin = create(:user, admin: true)
    organizer = create(:user)
    organizer.verify!(by: admin)
    organization = unverified_organization_for(organizer)
    run_migration
    first_pass = organization.reload.verified_at

    ActiveRecord::Migration.suppress_messages { described_class.new.up }

    expect(organization.reload.verified_at).to be_within(1.second).of(first_pass)
  end

  it "is irreversible rather than stripping verification staff may have changed" do
    expect { described_class.new.down }.to raise_error(ActiveRecord::IrreversibleMigration)
  end
end
