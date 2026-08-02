require "rails_helper"

RSpec.describe Certificate, type: :model do
  subject(:certificate) { build(:certificate) }

  describe "associations" do
    it { is_expected.to belong_to(:registration) }
  end

  describe "validations" do
    it "is valid with a registration that doesn't already have a certificate" do
      expect(certificate).to be_valid
    end

    it "rejects a second certificate for the same registration" do
      existing = create(:certificate)
      dupe = build(:certificate, registration: existing.registration)

      expect(dupe).not_to be_valid
      expect(dupe.errors[:registration_id]).to be_present
    end
  end

  describe "#file_present?" do
    it "is false when file_url is blank" do
      expect(certificate.file_present?).to be(false)
    end

    it "is true once file_url is set" do
      with_file = build(:certificate, :with_file)
      expect(with_file.file_present?).to be(true)
    end
  end
end
