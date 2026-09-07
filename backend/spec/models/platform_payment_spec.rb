require "rails_helper"

RSpec.describe PlatformPayment, type: :model do
  subject(:platform_payment) { build(:platform_payment) }

  describe "associations" do
    it { is_expected.to belong_to(:registration) }
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:provider) }
    it { is_expected.to validate_presence_of(:currency) }

    it "requires a unique tran_id" do
      create(:platform_payment, tran_id: "dupe123")
      expect(build(:platform_payment, tran_id: "dupe123")).not_to be_valid
    end

    it "requires a positive gross amount" do
      platform_payment.gross_amount_cents = 0
      expect(platform_payment).not_to be_valid
    end

    it "rejects an unknown status" do
      platform_payment.status = "settled"
      expect(platform_payment).not_to be_valid
    end

    it "rejects a refund larger than the gross amount" do
      platform_payment.refunded_amount_cents = platform_payment.gross_amount_cents + 1
      expect(platform_payment).not_to be_valid
    end
  end

  # The one invariant in this table that would be both silent and
  # unrecoverable if it ever broke, so it's checked in two places.
  describe "the gross = fee + net invariant" do
    it "accepts a split that adds up" do
      expect(build(:platform_payment,
        gross_amount_cents: 5000, platform_fee_cents: 600, host_net_cents: 4400)).to be_valid
    end

    it "rejects a split that doesn't, with a message naming all three numbers" do
      record = build(:platform_payment,
        gross_amount_cents: 5000, platform_fee_cents: 600, host_net_cents: 4000)

      expect(record).not_to be_valid
      expect(record.errors[:base].join).to include("600", "4000", "5000")
    end

    it "allows a zero platform fee, so a promotional or waived commission is expressible" do
      expect(build(:platform_payment,
        gross_amount_cents: 5000, platform_fee_cents: 0, host_net_cents: 5000)).to be_valid
    end

    # The validation above is bypassed by update_column, update_all and
    # insert_all. This is the check that still holds when it is.
    it "is enforced by the database even when validations are skipped" do
      record = create(:platform_payment)

      expect {
        record.update_column(:host_net_cents, record.host_net_cents + 1)
      }.to raise_error(ActiveRecord::StatementInvalid, /platform_payments_split_sums_to_gross/)
    end
  end

  describe "the two expiry clocks" do
    it "reports the QR window separately from the authorization hold" do
      record = build(:platform_payment, :qr_expired)

      expect(record).to be_qr_expired
      expect(record).not_to be_hold_expired
    end

    it "reports an aged-out hold without claiming the QR window matters" do
      record = build(:platform_payment, :hold_expired)

      expect(record).to be_hold_expired
    end

    it "treats a fresh authorization as neither" do
      record = build(:platform_payment, :authorized)

      expect(record).not_to be_qr_expired
      expect(record).not_to be_hold_expired
    end

    it "does not respond to a bare #expired?, which would be ambiguous here" do
      expect(platform_payment).not_to respond_to(:expired?)
    end
  end

  describe "#refundable?" do
    it "is false while the funds are only held, not captured" do
      expect(build(:platform_payment, :authorized)).not_to be_refundable
    end

    it "is true once captured" do
      expect(build(:platform_payment, :captured)).to be_refundable
    end

    it "is false once fully refunded" do
      record = build(:platform_payment, :captured,
        refunded_amount_cents: 2500, status: "refunded")

      expect(record).not_to be_refundable
      expect(record).to be_fully_refunded
    end

    it "is true again for the remainder after a partial refund" do
      record = build(:platform_payment, :captured,
        refunded_amount_cents: 1000, status: "partially_refunded")

      expect(record).to be_refundable
      expect(record.remaining_refundable_cents).to eq(1500)
      expect(record).to be_partially_refunded
    end
  end

  describe "AUTHORIZATION_WINDOW" do
    # Not a Rally policy — ABA auto-cancels an uncaptured pre-auth at 30 days.
    # If this constant ever drifts from what the gateway actually does, every
    # capture scheduled against it is wrong, so pin it.
    it "matches ABA's 30-day pre-auth ceiling" do
      expect(described_class::AUTHORIZATION_WINDOW).to eq(30.days)
    end
  end
end
