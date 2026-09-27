require "rails_helper"

# Phase 0 of docs/staff-roles-design.md claims to change no behaviour. This
# file is that claim, written down so it can fail.
#
# The valuable examples here are not the ones about the new column — they are
# the equivalence ones. `users.admin` and `users.staff_role` both exist and
# both must stay correct until Phase 3 retires the boolean, because thirteen
# call sites read one or the other and they move across in different phases.
# A divergence between the two is not a cosmetic bug: on one side it means a
# staff member silently keeps powers they were stripped of, and on the other
# it means an admin is locked out of the console.
RSpec.describe "User staff roles (Phase 0)", type: :model do
  describe "#admin?" do
    it "is true for a user whose role is admin" do
      user = create(:user, staff_role: "admin")

      expect(user.admin?).to be(true)
      expect(user).to be_staff
    end

    it "is false for every other role, and for nobody" do
      expect(create(:user, staff_role: "support").admin?).to be(false)
      expect(create(:user, staff_role: "moderator").admin?).to be(false)
      expect(create(:user).admin?).to be(false)
    end

    it "is false for a user with no role at all" do
      expect(create(:user)).not_to be_staff
    end
  end

  # ── The equivalence that makes Phase 0 a no-op ────────────────────────────
  #
  # 25 spec files across this suite create an admin with
  # `create(:user, admin: true)`. If the callback doesn't translate that into
  # a role, #admin? returns false and every one of them fails — which would at
  # least be loud. The quieter and worse version is the same thing happening
  # in a console against production.
  describe "granting admin the way it is actually granted" do
    it "promotes via the boolean, as the console does" do
      user = create(:user)

      user.update!(admin: true)

      expect(user.staff_role).to eq("admin")
      expect(user.admin?).to be(true)
      # Re-read from the database: the callback has to have persisted this,
      # not just set it on the in-memory object.
      expect(user.reload.staff_role).to eq("admin")
    end

    it "keeps `create(:user, admin: true)` working, which 25 spec files rely on" do
      user = create(:user, admin: true)

      expect(user.admin?).to be(true)
      expect(user.staff_role).to eq("admin")
    end

    it "revokes via the boolean, clearing the role entirely" do
      user = create(:user, admin: true)

      user.update!(admin: false)

      expect(user.reload.staff_role).to be_nil
      expect(user.admin?).to be(false)
      # Demotion is not a sideways move into a lesser staff role — that would
      # be a grant nobody requested.
      expect(user).not_to be_staff
    end
  end

  describe "the raw boolean, which four call sites still read directly" do
    it "is set when the role is assigned" do
      user = create(:user, staff_role: "admin")

      expect(user.reload[:admin]).to be(true)
      # The two scopes and ModerationNotifier's recipient query all go through
      # `where(admin: true)`. They must still find this person.
      expect(User.admins).to include(user)
      expect(User.where(admin: true)).to include(user)
    end

    it "is cleared when the role moves to a non-admin one" do
      user = create(:user, admin: true)

      user.update!(staff_role: "moderator")

      expect(user.reload[:admin]).to be(false)
      expect(User.admins).not_to include(user)
      # …but they are still staff, which is the whole point of the change.
      expect(user).to be_staff
      expect(User.staff).to include(user)
    end

    it "is never set for a non-admin staff role" do
      expect(create(:user, staff_role: "support").reload[:admin]).to be(false)
    end
  end

  # ── The database-level guard ──────────────────────────────────────────────
  #
  # The reconcile callback is a `before_save`, so `update_column`,
  # `update_all`, `insert_all`, `upsert_all` and raw SQL all route around it.
  # `users_admin_matches_staff_role` is what catches those, and these examples
  # are what prove the constraint is actually enforced rather than merely
  # declared in a migration nobody ran.
  #
  # Each example ends on the raise deliberately: a constraint violation aborts
  # the surrounding transaction, so any database work after it in the same
  # example would fail with PG::InFailedSqlTransaction and obscure the result.
  describe "the admin/staff_role consistency constraint" do
    it "refuses a role cleared behind the model's back" do
      user = create(:user, admin: true)

      expect { user.update_column(:staff_role, nil) }
        .to raise_error(ActiveRecord::StatementInvalid, /users_admin_matches_staff_role/)
    end

    it "refuses a boolean raised behind the model's back" do
      user = create(:user)

      expect { user.update_column(:admin, true) }
        .to raise_error(ActiveRecord::StatementInvalid, /users_admin_matches_staff_role/)
    end

    # The case that decides the SQL spelling. `admin = (staff_role = 'admin')`
    # evaluates to NULL here, and a CHECK that evaluates to NULL *passes* — so
    # under the obvious spelling this desync would be allowed and the
    # constraint would police admins only. `IS NOT DISTINCT FROM` is what
    # makes it total.
    it "refuses an admin boolean with no role at all" do
      user = create(:user)

      expect { user.update_columns(admin: true, staff_role: nil) }
        .to raise_error(ActiveRecord::StatementInvalid, /users_admin_matches_staff_role/)
    end

    # Positive controls: the constraint must permit every consistent pair, or
    # it is just blocking raw writes rather than enforcing agreement.
    it "permits a consistent admin pair written raw" do
      user = create(:user)

      expect { user.update_columns(admin: true, staff_role: "admin") }.not_to raise_error
    end

    it "permits non-admin staff, where the boolean is false" do
      user = create(:user)

      expect { user.update_columns(admin: false, staff_role: "moderator") }.not_to raise_error
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

  # Ordered least- to most-privileged. Nothing reads the ordering in Phase 0 —
  # the capability matrix lands in Phase 1 — but the constant is the thing
  # that matrix will be written against, so pin it now rather than discovering
  # later that someone alphabetised it.
  it "declares the roles in ascending order of privilege" do
    expect(User::STAFF_ROLES).to eq(%w[support moderator admin])
    expect(User::ADMIN_ROLE).to eq("admin")
  end
end
