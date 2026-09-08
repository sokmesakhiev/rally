require "rails_helper"

RSpec.describe HostLedgerEntry, type: :model do
  let(:organization) { create(:organization) }

  def entry(attrs)
    described_class.new({ organization: organization, currency: "usd" }.merge(attrs))
  end

  describe "validations" do
    it "rejects a zero-value entry, which records nothing" do
      expect(entry(entry_type: "adjustment", amount_cents: 0, description: "x")).not_to be_valid
    end

    it "rejects an unknown entry type" do
      expect(entry(entry_type: "vibes", amount_cents: 100)).not_to be_valid
    end

    it "requires a description on a manual adjustment" do
      expect(entry(entry_type: "adjustment", amount_cents: -100)).not_to be_valid
      expect(entry(entry_type: "adjustment", amount_cents: -100, description: "goodwill")).to be_valid
    end

    # A clawback recorded with the wrong sign pays the host a second time
    # instead of recovering from them, and nothing downstream would notice.
    describe "sign matching the entry type" do
      it "requires a capture to be a credit" do
        expect(entry(entry_type: "registration_capture", amount_cents: -100)).not_to be_valid
        expect(entry(entry_type: "registration_capture", amount_cents: 100)).to be_valid
      end

      it "requires a clawback to be a debit" do
        expect(entry(entry_type: "refund_clawback", amount_cents: 100)).not_to be_valid
        expect(entry(entry_type: "refund_clawback", amount_cents: -100)).to be_valid
      end

      it "requires a payout to be a debit" do
        expect(entry(entry_type: "payout", amount_cents: 100)).not_to be_valid
      end

      it "lets an adjustment go either way" do
        expect(entry(entry_type: "adjustment", amount_cents: 100, description: "x")).to be_valid
        expect(entry(entry_type: "adjustment", amount_cents: -100, description: "x")).to be_valid
      end
    end
  end

  describe "append-only" do
    let!(:existing) do
      described_class.create!(organization: organization, entry_type: "registration_capture",
        amount_cents: 2000, currency: "usd")
    end

    it "refuses updates" do
      expect { existing.update!(amount_cents: 5000) }.to raise_error(ActiveRecord::ReadOnlyRecord)
    end

    it "refuses destroys" do
      expect { existing.destroy! }.to raise_error(ActiveRecord::ReadOnlyRecord)
    end

    it "records a correction as a new compensating entry instead" do
      described_class.create!(organization: organization, entry_type: "adjustment",
        amount_cents: -500, currency: "usd", description: "overpaid on capture")

      expect(organization.ledger_balance_cents).to eq(1500)
      expect(organization.host_ledger_entries.count).to eq(2)
    end
  end

  describe "balance" do
    it "is zero for an organization with no history" do
      expect(organization.ledger_balance_cents).to eq(0)
    end

    it "nets credits against debits" do
      described_class.create!(organization: organization, entry_type: "registration_capture",
        amount_cents: 10_000, currency: "usd")
      described_class.create!(organization: organization, entry_type: "payout",
        amount_cents: -8_000, currency: "usd")
      described_class.create!(organization: organization, entry_type: "refund_clawback",
        amount_cents: -500, currency: "usd")

      expect(organization.ledger_balance_cents).to eq(1_500)
    end

    it "goes negative when a clawback lands after the host has been paid out" do
      described_class.create!(organization: organization, entry_type: "registration_capture",
        amount_cents: 2_500, currency: "usd")
      described_class.create!(organization: organization, entry_type: "payout",
        amount_cents: -2_500, currency: "usd")
      described_class.create!(organization: organization, entry_type: "refund_clawback",
        amount_cents: -2_500, currency: "usd")

      expect(organization.ledger_balance_cents).to eq(-2_500)
    end

    it "doesn't count another organization's entries" do
      other = create(:organization)
      described_class.create!(organization: other, entry_type: "registration_capture",
        amount_cents: 9_999, currency: "usd")

      expect(organization.ledger_balance_cents).to eq(0)
    end
  end

  describe "#in_arrears?" do
    it "is false at a zero balance" do
      expect(organization).not_to be_in_arrears
    end

    it "is false for a small negative balance that will net off next event" do
      described_class.create!(organization: organization, entry_type: "refund_clawback",
        amount_cents: -(HostLedgerEntry::ARREARS_THRESHOLD_CENTS - 1), currency: "usd")

      expect(organization.reload).not_to be_in_arrears
    end

    it "is true once the debt passes the threshold" do
      described_class.create!(organization: organization, entry_type: "refund_clawback",
        amount_cents: -(HostLedgerEntry::ARREARS_THRESHOLD_CENTS + 1), currency: "usd")

      expect(organization.reload).to be_in_arrears
    end

    it "is false for a host who is owed money" do
      described_class.create!(organization: organization, entry_type: "registration_capture",
        amount_cents: 100_000, currency: "usd")

      expect(organization.reload).not_to be_in_arrears
    end
  end
end
