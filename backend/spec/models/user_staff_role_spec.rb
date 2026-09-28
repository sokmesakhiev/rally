require "rails_helper"

# `users.staff_role` is now the only representation of staff status.
#
# This file used to carry a second set of examples proving the role and the
# legacy `users.admin` boolean agreed — through the reconcile callback and a
# CHECK constraint. Phase 3 removed both, so those examples went with them
# rather than being left to describe machinery that no longer exists. The
# history is in docs/staff-roles-design.md D2 if the cutover ever needs
# repeating for another column.
RSpec.describe "User staff roles", type: :model do
  describe "#admin?" do
    it "is true for a user whose role is admin" do
      user = create(:user, :admin)

      expect(user.admin?).to be(true)
      expect(user).to be_staff
    end

    it "is false for every other role" do
      expect(create(:user, :support).admin?).to be(false)
      expect(create(:user, :moderator).admin?).to be(false)
    end

    it "is false, and not staff at all, for an ordinary account" do
      user = create(:user)

      expect(user.admin?).to be(false)
      expect(user).not_to be_staff
    end
  end

  describe "#staff?" do
    it "is true for all three roles" do
      User::STAFF_ROLES.each do |role|
        expect(create(:user, staff_role: role)).to be_staff, "#{role} did not count as staff"
      end
    end
  end

  describe "scopes" do
    it "finds admins by role" do
      admin = create(:user, :admin)
      create(:user, :moderator)
      create(:user)

      expect(User.admins).to contain_exactly(admin)
    end

    it "finds every staff member, whatever the role" do
      staff = User::STAFF_ROLES.map { |role| create(:user, staff_role: role) }
      create(:user)

      expect(User.staff).to match_array(staff)
    end
  end

  describe "granting and revoking from the console" do
    # There is deliberately no endpoint for this — see
    # Api::V1::Admin::BaseController. The console is the only way in, so the
    # console's one-liner is worth an example.
    it "promotes by setting the role" do
      user = create(:user)

      user.update!(staff_role: "moderator")

      expect(user.reload.staff_role).to eq("moderator")
      expect(user).to be_staff
    end

    it "revokes by clearing it" do
      # Not an admin: demoting the last one is refused by design, and that
      # rule has its own examples in staff_role_assignment_spec.rb. Here the
      # subject is that clearing the column removes staff status at all.
      user = create(:user, :moderator)

      user.update!(staff_role: nil)

      expect(user.reload).not_to be_staff
      expect(user.admin?).to be(false)
    end
  end

  describe "validation" do
    it "accepts the three declared roles and nil" do
      expect(build(:user, staff_role: nil)).to be_valid
      User::STAFF_ROLES.each do |role|
        expect(build(:user, staff_role: role)).to be_valid, "#{role} should be a valid staff role"
      end
    end

    it "rejects anything else" do
      user = build(:user, staff_role: "superuser")

      expect(user).not_to be_valid
      expect(user.errors[:staff_role]).to be_present
    end
  end

  # Ordered least- to most-privileged. StaffAuthorization::CAPABILITIES is
  # written against these names, and spec/requests/admin_capability_coverage_spec.rb
  # asserts the matrix uses no others.
  it "declares the roles in ascending order of privilege" do
    expect(User::STAFF_ROLES).to eq(%w[support moderator admin])
    expect(User::ADMIN_ROLE).to eq("admin")
  end
end
