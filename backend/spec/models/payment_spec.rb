require "rails_helper"

RSpec.describe Payment, type: :model do
  subject(:payment) { build(:payment) }

  describe "associations" do
    it { is_expected.to belong_to(:registration) }
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:provider) }
    it { is_expected.to validate_presence_of(:currency) }

    it "requires a unique tran_id" do
      create(:payment, tran_id: "dupe123")
      dup = build(:payment, tran_id: "dupe123")
      expect(dup).not_to be_valid
    end

    it "requires a positive amount" do
      payment.amount_cents = 0
      expect(payment).not_to be_valid
    end
  end

  describe "#formatted_amount" do
    it "formats USD with 2 decimal places" do
      payment = build(:payment, amount_cents: 2599, currency: "usd")
      expect(payment.formatted_amount).to eq("25.99")
    end

    it "formats KHR with no decimal places" do
      payment = build(:payment, amount_cents: 400_000, currency: "khr")
      expect(payment.formatted_amount).to eq("4000")
    end
  end

  describe "#expired?" do
    it "is true once expires_at has passed" do
      payment = build(:payment, :expired)
      expect(payment.expired?).to be(true)
    end

    it "is false when there is time left" do
      payment = build(:payment, expires_at: 5.minutes.from_now)
      expect(payment.expired?).to be(false)
    end
  end

  describe "#approved?" do
    it "reflects the approved status" do
      expect(build(:payment, :approved).approved?).to be(true)
      expect(build(:payment, status: "pending").approved?).to be(false)
    end
  end
end
