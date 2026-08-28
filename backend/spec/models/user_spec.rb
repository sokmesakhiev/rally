require "rails_helper"

RSpec.describe User, type: :model do
  subject(:user) { build(:user) }

  # ── Associations ─────────────────────────────────────────────────────────────
  describe "associations" do
    it { is_expected.to have_one(:profile).dependent(:destroy) }
    it { is_expected.to have_many(:events).with_foreign_key(:creator_id).dependent(:destroy) }
    it { is_expected.to have_many(:registrations).dependent(:destroy) }
    # restrict_with_error, not destroy: an organization presents events other
    # people have paid to register for, so deleting the account can't quietly
    # take it down.
    it {
      is_expected.to have_many(:owned_organizations)
        .class_name("Organization").with_foreign_key(:owner_id).dependent(:restrict_with_error)
    }
    it { is_expected.to have_many(:organization_memberships).dependent(:destroy) }
  end

  # ── Organizations ────────────────────────────────────────────────────────────
  # The set a user may act for — what Ticket C (#332) uses to widen
  # EventAuthorization and my_events, and what the frontend org switcher lists.
  describe "#administered_organizations" do
    let(:user) { create(:user) }

    it "includes organizations the user owns" do
      owned = create(:organization, owner: user)

      expect(user.administered_organizations).to include(owned)
    end

    it "includes organizations where the user is an admin" do
      org = create(:organization)
      create(:organization_membership, organization: org, user: user, role: "admin")

      expect(user.administered_organizations).to include(org)
    end

    it "excludes organizations where the user is only a plain member" do
      org = create(:organization)
      create(:organization_membership, organization: org, user: user, role: "member")

      expect(user.administered_organizations).not_to include(org)
    end

    it "excludes organizations the user has no relationship with" do
      stranger_org = create(:organization)

      expect(user.administered_organizations).not_to include(stranger_org)
    end

    # People genuinely work with several organizations at once — their own
    # race series plus a club they volunteer for.
    it "spans owned and administered organizations together, without duplicates" do
      owned_one = create(:organization, owner: user)
      owned_two = create(:organization, owner: user)
      admin_of = create(:organization)
      create(:organization_membership, organization: admin_of, user: user, role: "admin")

      expect(user.administered_organizations)
        .to contain_exactly(owned_one, owned_two, admin_of)
    end

    it "is empty for a participant who organizes nothing" do
      expect(user.administered_organizations).to be_empty
    end
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

    it "scrubs the profile's PII" do
      user = create(:user)
      user.profile.update!(
        display_name: "Real Name",
        avatar_url: "https://example.com/a.png",
        phone: "012345678"
      )

      user.discard!

      profile = user.profile.reload
      expect(profile.display_name).to be_nil
      expect(profile.avatar_url).to be_nil
      expect(profile.phone).to be_nil
    end

    # PayWay credentials live on Organization since #331, so scrubbing them
    # means scrubbing them there. A deleted account's live merchant
    # credentials must not linger on an organization that outlives it.
    it "clears PayWay credentials from every organization the user owns" do
      user = create(:user)
      first = create(:organization, owner: user)
      second = create(:organization, owner: user)
      [ first, second ].each do |org|
        org.update!(
          payway_merchant_id: "merchant123",
          payway_api_key: "secret-key",
          payway_rsa_public_key: "-----BEGIN PUBLIC KEY-----"
        )
      end

      user.discard!

      [ first, second ].each do |org|
        org.reload
        expect(org.payway_merchant_id).to be_nil
        expect(org.payway_api_key).to be_nil
        expect(org.payway_rsa_public_key).to be_nil
      end
    end

    # The organizations themselves survive — they present events other people
    # registered for, the same reason #discard! hides events rather than
    # destroying them.
    it "leaves the organizations themselves in place" do
      user = create(:user)
      organization = create(:organization, owner: user)

      user.discard!

      expect(Organization.exists?(organization.id)).to be(true)
    end

    it "does not touch PayWay credentials on organizations the user merely administers" do
      user = create(:user)
      club = create(:organization)
      club.update!(payway_merchant_id: "club_merchant", payway_api_key: "club_key")
      create(:organization_membership, organization: club, user: user, role: "admin")

      user.discard!

      expect(club.reload.payway_merchant_id).to eq("club_merchant")
    end

    it "resets email_auto_generated so a deleted account doesn't linger in the 'add a real email' nudge" do
      checkout = Registrations::GuestCheckout.call(email: nil, phone: "012345678", name: "Guest")
      user = checkout.user
      expect(user.email_auto_generated?).to be(true)

      user.discard!

      expect(user.reload.email_auto_generated?).to be(false)
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
