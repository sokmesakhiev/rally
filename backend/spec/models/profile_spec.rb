require "rails_helper"

RSpec.describe Profile, type: :model do
  # ── Associations ─────────────────────────────────────────────────────────────
  describe "associations" do
    it { is_expected.to belong_to(:user) }
  end

  # ── Validations ──────────────────────────────────────────────────────────────
  describe "validations" do
    it "enforces one profile per user" do
      user = create(:user)           # profile auto-created
      duplicate = build(:profile, user: user)
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:user_id]).to be_present
    end
  end

  # ── Attributes ───────────────────────────────────────────────────────────────
  describe "attributes" do
    it "allows display_name and avatar_url to be nil" do
      profile = create(:user).profile
      profile.update!(display_name: nil, avatar_url: nil)
      expect(profile).to be_persisted
    end

    it "can store a display_name" do
      profile = create(:user).profile
      profile.update!(display_name: "Alex Runner")
      expect(profile.reload.display_name).to eq("Alex Runner")
    end
  end
end
