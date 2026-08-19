require "rails_helper"

# User#after_create already builds a Profile for every user (see
# User#create_profile!) — create(:profile, ...) would hit Profile's
# `validates :user_id, uniqueness: true` against that auto-created row (see
# certificates/render_pdf_spec.rb for the same gotcha), so every example
# here starts from create(:user).profile instead of the :profile factory.
RSpec.describe Profile, type: :model do
  # ── Phone ────────────────────────────────────────────────────────────────────
  describe "phone" do
    it "accepts common Cambodian phone formats" do
      [ "012 345 678", "+855 12 345 678", "0123456789", "023-456-789" ].each do |phone|
        profile = create(:user).profile
        profile.phone = phone
        expect(profile).to be_valid, "expected #{phone.inspect} to be valid"
      end
    end

    it "rejects something that isn't a phone number" do
      profile = create(:user).profile
      profile.phone = "not a phone number!!"

      expect(profile).not_to be_valid
      expect(profile.errors[:phone]).to be_present
    end

    it "treats a blank phone the same as no phone" do
      profile = create(:user).profile
      profile.phone = ""
      profile.valid?

      expect(profile.phone).to be_nil
    end

    it "enforces uniqueness, blank/nil allowed for many rows" do
      create(:user).profile.update!(phone: "012345678")
      duplicate = create(:user).profile
      duplicate.phone = "012345678"

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:phone]).to be_present
    end

    it "allows multiple profiles with no phone" do
      create(:user) # profile.phone stays nil
      other = create(:user).profile

      expect(other).to be_valid
    end
  end
end
