require "rails_helper"

RSpec.describe Registrations::GuestCheckout, type: :model do
  describe ".call" do
    it "creates a new user with a random password and sets the display name" do
      result = described_class.call(email: "  Dara@Example.com  ", name: "  Dara Kim  ")

      expect(result.ok?).to be(true)
      user = result.user
      expect(user).to be_persisted
      expect(user.email).to eq("dara@example.com")
      expect(user.profile.display_name).to eq("Dara Kim")
      expect(user.authenticate("wrong-password")).to be(false)
    end

    it "leaves display_name blank when no name is given" do
      result = described_class.call(email: "dara@example.com", name: "")

      expect(result.user.profile.display_name).to be_nil
    end

    it "returns a conflict result instead of reusing an existing account" do
      existing = create(:user)

      result = described_class.call(email: existing.email, name: "Someone Else")

      expect(result.ok?).to be(false)
      expect(result.status).to eq(:conflict)
      expect(result.user).to be_nil
    end
  end
end
