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

  # ── Email verification ────────────────────────────────────────────────────────
  describe "email verification" do
    it "is assigned a verification token automatically on create" do
      user = create(:user)
      expect(user.email_verification_token).to be_present
      expect(user.email_verified?).to be(false)
    end

    it "verify_email! clears the token and sets email_verified_at" do
      user = create(:user)
      user.verify_email!
      expect(user.email_verified?).to be(true)
      expect(user.email_verification_token).to be_nil
    end

    it "finds a user by a valid token" do
      user = create(:user)
      expect(User.find_by_valid_email_verification_token(user.email_verification_token)).to eq(user)
    end

    it "does not find a user by an expired token" do
      user = create(:user)
      user.update_column(:email_verification_sent_at, 4.days.ago)
      expect(User.find_by_valid_email_verification_token(user.email_verification_token)).to be_nil
    end

    it "returns nil for an unknown token" do
      expect(User.find_by_valid_email_verification_token("bogus")).to be_nil
    end
  end

  # ── Password reset ────────────────────────────────────────────────────────────
  describe "password reset" do
    it "generate_password_reset_token! sets a token and timestamp" do
      user = create(:user)
      user.generate_password_reset_token!
      expect(user.password_reset_token).to be_present
      expect(user.password_reset_token_valid?).to be(true)
    end

    it "is invalid once expired" do
      user = create(:user)
      user.generate_password_reset_token!
      user.update_column(:password_reset_sent_at, 3.hours.ago)
      expect(user.password_reset_token_valid?).to be(false)
    end

    it "finds a user by a valid reset token" do
      user = create(:user)
      user.generate_password_reset_token!
      expect(User.find_by_valid_password_reset_token(user.password_reset_token)).to eq(user)
    end

    it "reset_password! updates the password and clears the token" do
      user = create(:user, password: "oldpassword")
      user.generate_password_reset_token!
      user.reset_password!("newpassword123")

      expect(user.reload.authenticate("newpassword123")).to eq(user)
      expect(user.password_reset_token).to be_nil
    end
  end
end
