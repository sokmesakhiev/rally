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

  # ── Self-service account deletion ─────────────────────────────────────────────
  describe "#discard!" do
    it "anonymizes email, disables sign-in, and marks deleted_at without destroying the row" do
      user = create(:user, email: "real@example.com", password: "securepass")
      user.profile.update!(display_name: "Real Name", avatar_url: "https://example.com/a.png")

      expect { user.discard! }.not_to change(User, :count)

      user.reload
      expect(user.discarded?).to be(true)
      expect(user.email).to eq("deleted-#{user.id}@deleted.rally.invalid")
      expect(user.authenticate("securepass")).to be_falsey
      expect(User.kept).not_to include(user)
      expect(User.discarded).to include(user)
    end

    it "scrubs the profile's PII and PayWay credentials" do
      user = create(:user)
      user.profile.update!(
        display_name: "Real Name",
        avatar_url: "https://example.com/a.png",
        payway_merchant_id: "merchant123",
        payway_api_key: "secret-key"
      )

      user.discard!

      profile = user.profile.reload
      expect(profile.display_name).to be_nil
      expect(profile.avatar_url).to be_nil
      expect(profile.payway_merchant_id).to be_nil
      expect(profile.payway_api_key).to be_nil
    end

    it "clears google_uid so the same Google account can sign up fresh afterwards" do
      user = create(:user, google_uid: "google-123", provider: "google")

      user.discard!

      expect(user.reload.google_uid).to be_nil
    end

    it "hides (discards) the user's own events, cascading to their registrations" do
      user = create(:user)
      event = create(:event, creator: user)
      other_participant = create(:user)
      registration = create(:registration, event: event, user: other_participant)

      user.discard!

      expect(event.reload.discarded?).to be(true)
      expect(registration.reload.discarded?).to be(true)
      # The other participant's own account is untouched.
      expect(other_participant.reload.discarded?).to be(false)
    end

    it "does not destroy other users' payments/refunds tied to the deleted user's events" do
      user = create(:user)
      event = create(:event, creator: user, price_cents: 2500)
      registration = create(:registration, :paid, event: event)
      payment = create(:payment, :approved, registration: registration)

      user.discard!

      expect(Payment.exists?(payment.id)).to be(true)
    end
  end
end
