require "rails_helper"

RSpec.describe Registrations::GuestCheckout, type: :model do
  describe ".call" do
    it "creates a new user with a random password and sets the display name" do
      result = described_class.call(email: "  Dara@Example.com  ", phone: nil, name: "  Dara Kim  ")

      expect(result.ok?).to be(true)
      expect(result.newly_created).to be(true)
      user = result.user
      expect(user).to be_persisted
      expect(user.email).to eq("dara@example.com")
      expect(user.email_auto_generated?).to be(false)
      expect(user.profile.display_name).to eq("Dara Kim")
      expect(user.authenticate("wrong-password")).to be(false)
    end

    it "leaves display_name blank when no name is given" do
      result = described_class.call(email: "dara@example.com", phone: nil, name: "")

      expect(result.user.profile.display_name).to be_nil
    end

    it "attaches to the existing account instead of creating a duplicate when the email matches" do
      existing = create(:user)

      result = described_class.call(email: existing.email, phone: nil, name: "Someone Else")

      expect(result.ok?).to be(true)
      expect(result.newly_created).to be(false)
      expect(result.user).to eq(existing)
      expect(User.where(email: existing.email).count).to eq(1)
    end

    it "does not overwrite the existing account's profile with the newly typed name/phone" do
      existing = create(:user)
      existing.profile.update!(display_name: "Real Name", phone: "011111111")

      described_class.call(email: existing.email, phone: nil, name: "Someone Else")

      expect(existing.profile.reload.display_name).to eq("Real Name")
      expect(existing.profile.phone).to eq("011111111")
    end

    # ── Phone-only registration — Cambodia's most common contact channel ────────
    describe "phone-only (no email given)" do
      it "creates an account with an auto-generated placeholder email, flagged as such" do
        result = described_class.call(email: nil, phone: "012 345 678", name: "Dara Kim")

        expect(result.ok?).to be(true)
        user = result.user
        expect(user.email).to match(/\Aguest-[0-9a-f]+@guest\.rally\.invalid\z/)
        expect(user.email_auto_generated?).to be(true)
        expect(user.profile.phone).to eq("012 345 678")
        expect(user.profile.display_name).to eq("Dara Kim")
      end

      it "generates a different placeholder email for each guest, so two phone-only guests don't collide" do
        first = described_class.call(email: nil, phone: "012345678", name: "A").user
        second = described_class.call(email: nil, phone: "098765432", name: "B").user

        expect(first.email).not_to eq(second.email)
      end
    end

    describe "both email and phone given" do
      it "uses the real email (not a placeholder) and still saves the phone" do
        result = described_class.call(email: "dara@example.com", phone: "012345678", name: "Dara Kim")

        user = result.user
        expect(user.email).to eq("dara@example.com")
        expect(user.email_auto_generated?).to be(false)
        expect(user.profile.phone).to eq("012345678")
      end
    end

    describe "phone already registered" do
      it "attaches to the existing account instead of creating a duplicate" do
        existing = create(:user)
        existing.profile.update!(phone: "012345678")

        result = described_class.call(email: nil, phone: "012345678", name: "Someone Else")

        expect(result.ok?).to be(true)
        expect(result.user).to eq(existing)
        expect(User.count).to eq(1)
      end
    end

    describe "email and phone match two different accounts" do
      it "prefers the email match" do
        by_email = create(:user)
        by_phone = create(:user)
        by_phone.profile.update!(phone: "012345678")

        result = described_class.call(email: by_email.email, phone: "012345678", name: "Someone")

        expect(result.user).to eq(by_email)
      end
    end
  end
end
