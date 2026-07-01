require "rails_helper"

RSpec.describe User, type: :model do
  subject(:user) { build(:user) }

  # ── Associations ─────────────────────────────────────────────────────────────
  describe "associations" do
    it { is_expected.to have_one(:profile).dependent(:destroy) }
    it { is_expected.to have_many(:events).with_foreign_key(:creator_id).dependent(:destroy) }
    it { is_expected.to have_many(:registrations).dependent(:destroy) }
  end

  # ── Validations ──────────────────────────────────────────────────────────────
  describe "validations" do
    it { is_expected.to validate_presence_of(:email) }
    it { is_expected.to validate_uniqueness_of(:email).case_insensitive }

    it "rejects a malformed email" do
      user.email = "not-an-email"
      expect(user).not_to be_valid
      expect(user.errors[:email]).to be_present
    end

    it "requires password to be at least 8 characters" do
      user.password = "short"
      expect(user).not_to be_valid
      expect(user.errors[:password]).to be_present
    end

    it "accepts a valid email and password" do
      expect(user).to be_valid
    end
  end

  # ── Callbacks ────────────────────────────────────────────────────────────────
  describe "after create" do
    it "automatically creates a profile" do
      user = create(:user)
      expect(user.profile).to be_present
    end
  end

  # ── Password ─────────────────────────────────────────────────────────────────
  describe "#authenticate" do
    let!(:persisted) { create(:user, password: "securepass") }

    it "returns the user when the password matches" do
      expect(persisted.authenticate("securepass")).to eq(persisted)
    end

    it "returns false when the password is wrong" do
      expect(persisted.authenticate("wrongpass")).to be_falsey
    end
  end

  # ── Email normalisation ───────────────────────────────────────────────────────
  describe "email normalisation" do
    it "downcases email before save" do
      user = create(:user, email: "USER@EXAMPLE.COM")
      expect(user.reload.email).to eq("user@example.com")
    end

    it "strips whitespace from email before save" do
      user = create(:user, email: "  user@example.com  ")
      expect(user.reload.email).to eq("user@example.com")
    end
  end
end
