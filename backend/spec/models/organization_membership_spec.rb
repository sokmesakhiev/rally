require "rails_helper"

RSpec.describe OrganizationMembership, type: :model do
  describe "associations" do
    it { is_expected.to belong_to(:organization) }
    it { is_expected.to belong_to(:user) }
    it { is_expected.to belong_to(:invited_by).class_name("User").optional }
  end

  describe "validations" do
    it "accepts every role in ROLES" do
      described_class::ROLES.each do |role|
        membership = build(:organization_membership, role: role)
        expect(membership).to be_valid, "expected #{role} to be valid"
      end
    end

    it "rejects an unknown role" do
      membership = build(:organization_membership, role: "superuser")

      expect(membership).not_to be_valid
      expect(membership.errors[:role]).to be_present
    end

    # "owner" is deliberately not a membership role — ownership lives on
    # organizations.owner_id, so there is no way to end up with two owners.
    it "rejects 'owner' as a role" do
      membership = build(:organization_membership, role: "owner")

      expect(membership).not_to be_valid
      expect(described_class::ROLES).not_to include("owner")
    end

    it "allows only one membership per person per organization" do
      organization = create(:organization)
      user = create(:user)
      create(:organization_membership, organization: organization, user: user)

      duplicate = build(:organization_membership, organization: organization, user: user)

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:user_id]).to be_present
    end

    it "allows the same person to belong to several organizations" do
      user = create(:user)
      create(:organization_membership, organization: create(:organization), user: user)
      second = build(:organization_membership, organization: create(:organization), user: user)

      expect(second).to be_valid
    end

    # The owner's authority comes from Organization#owner_id. A row here for
    # them would be a second, contradictable source of truth, and would make
    # Organization#team list them twice.
    it "refuses a membership row for the organization's own owner" do
      owner = create(:user)
      organization = create(:organization, owner: owner)

      membership = build(:organization_membership, organization: organization, user: owner)

      expect(membership).not_to be_valid
      expect(membership.errors[:user_id]).to be_present
    end
  end

  describe "#admin?" do
    it "is true only for the admin role" do
      expect(build(:organization_membership, :admin).admin?).to be(true)
      expect(build(:organization_membership, :member).admin?).to be(false)
    end
  end

  describe ".admins" do
    it "returns admin rows only" do
      organization = create(:organization)
      admin = create(:organization_membership, :admin, organization: organization)
      create(:organization_membership, :member, organization: organization)

      expect(organization.organization_memberships.admins).to contain_exactly(admin)
    end
  end
end
