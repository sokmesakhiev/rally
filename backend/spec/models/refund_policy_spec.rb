require "rails_helper"

RSpec.describe RefundPolicy do
  # 100% up to 7 days out, 50% up to 48 hours out, nothing after.
  let(:standard) { described_class.template("standard") }

  describe ".from" do
    it "returns nil for nil, keeping 'no policy' distinct from 'no refunds'" do
      expect(described_class.from(nil)).to be_nil
    end

    it "returns an explicitly non-refundable policy for an empty array" do
      policy = described_class.from([])

      expect(policy).not_to be_nil
      expect(policy).to be_non_refundable
    end

    it "reads tiers that came back from jsonb with string keys" do
      policy = described_class.from([ { "hours_before" => 48, "refund_percent" => 50 } ])

      expect(policy.tiers.first.hours_before).to eq(48)
      expect(policy.tiers.first.refund_percent).to eq(50)
    end
  end

  describe "#refund_percent_for" do
    it "gives the full tier well before the cutoff" do
      expect(standard.refund_percent_for(24 * 30)).to eq(100)
    end

    it "gives nothing once every cutoff has passed" do
      expect(standard.refund_percent_for(1)).to eq(0)
    end

    it "gives the middle tier between two cutoffs" do
      expect(standard.refund_percent_for(100)).to eq(50)
    end

    # The boundaries are where a policy argument actually happens, so pin them
    # exactly rather than testing "around" them.
    describe "at the boundaries" do
      it "includes the cutoff itself — 'at least 7 days before' means 7 days counts" do
        expect(standard.refund_percent_for(168)).to eq(100)
      end

      it "drops to the next tier one hour inside the cutoff" do
        expect(standard.refund_percent_for(167)).to eq(50)
      end

      it "still pays the last tier exactly on its cutoff" do
        expect(standard.refund_percent_for(48)).to eq(50)
      end

      it "pays nothing one hour inside the last cutoff" do
        expect(standard.refund_percent_for(47)).to eq(0)
      end
    end

    it "treats an event that has already started as past every cutoff" do
      expect(standard.refund_percent_for(-5)).to eq(0)
    end

    it "returns 0 rather than raising when the event has no start date" do
      expect(standard.refund_percent_for(nil)).to eq(0)
    end

    it "gives nothing at any point under a non-refundable policy" do
      policy = described_class.template("non_refundable")

      expect(policy.refund_percent_for(24 * 365)).to eq(0)
    end

    # Ordering is validated on the way in, but evaluation deliberately does
    # not depend on it having held — a legacy or hand-edited row should still
    # get a defensible answer.
    it "takes the most generous qualifying tier regardless of stored order" do
      jumbled = described_class.new([
        { hours_before: 48,  refund_percent: 50 },
        { hours_before: 168, refund_percent: 100 }
      ])

      expect(jumbled.refund_percent_for(200)).to eq(100)
      expect(jumbled.refund_percent_for(100)).to eq(50)
    end
  end

  describe "#refund_amount_cents" do
    it "returns everything for a 100% tier" do
      expect(standard.refund_amount_cents(2500, hours_until_start: 500)).to eq(2500)
    end

    it "returns nothing once past every cutoff" do
      expect(standard.refund_amount_cents(2500, hours_until_start: 1)).to eq(0)
    end

    it "takes the percentage for a partial tier" do
      expect(standard.refund_amount_cents(2500, hours_until_start: 100)).to eq(1250)
    end

    it "rounds a fractional cent rather than truncating it" do
      expect(standard.refund_amount_cents(999, hours_until_start: 100)).to eq(500)
    end

    it "never returns more than was paid" do
      expect(standard.refund_amount_cents(1, hours_until_start: 500)).to eq(1)
    end

    it "returns 0 for a free registration" do
      expect(standard.refund_amount_cents(0, hours_until_start: 500)).to eq(0)
    end
  end

  describe "validation" do
    it "accepts every shipped template" do
      described_class.template_names.each do |name|
        expect(described_class.template(name)).to be_valid, "expected #{name} to be valid"
      end
    end

    it "rejects two tiers sharing a cutoff, which has no single answer" do
      policy = described_class.new([
        { hours_before: 48, refund_percent: 100 },
        { hours_before: 48, refund_percent: 50 }
      ])

      expect(policy).not_to be_valid
      expect(policy.errors.join).to match(/no two the same/)
    end

    it "rejects cutoffs that don't decrease" do
      policy = described_class.new([
        { hours_before: 24,  refund_percent: 100 },
        { hours_before: 168, refund_percent: 50 }
      ])

      expect(policy).not_to be_valid
    end

    # Always a data-entry mistake, and much cheaper to catch than to honour.
    it "rejects a percentage that increases as the event gets closer" do
      policy = described_class.new([
        { hours_before: 168, refund_percent: 50 },
        { hours_before: 48,  refund_percent: 100 }
      ])

      expect(policy).not_to be_valid
      expect(policy.errors.join).to match(/cannot increase/)
    end

    it "allows two tiers at the same percentage" do
      policy = described_class.new([
        { hours_before: 168, refund_percent: 50 },
        { hours_before: 48,  refund_percent: 50 }
      ])

      expect(policy).to be_valid
    end

    it "rejects a percentage above 100" do
      expect(described_class.new([ { hours_before: 24, refund_percent: 101 } ])).not_to be_valid
    end

    it "rejects a negative lead time" do
      expect(described_class.new([ { hours_before: -1, refund_percent: 50 } ])).not_to be_valid
    end

    it "rejects junk that can't be read as a number, without raising" do
      policy = described_class.new([ { hours_before: "soon", refund_percent: 50 } ])

      expect(policy).not_to be_valid
      expect(policy.errors.join).to match(/whole number/)
    end

    it "rejects more tiers than MAX_TIERS" do
      tiers = (1..described_class::MAX_TIERS + 1).map do |i|
        { hours_before: 1000 - i, refund_percent: 50 }
      end

      expect(described_class.new(tiers)).not_to be_valid
    end
  end

  describe "#template_name" do
    it "recognises a policy that matches a shipped preset" do
      expect(standard.template_name).to eq("standard")
    end

    it "recognises an empty policy as non_refundable" do
      expect(described_class.new([]).template_name).to eq("non_refundable")
    end

    it "is nil for a custom policy" do
      custom = described_class.new([ { hours_before: 72, refund_percent: 80 } ])

      expect(custom.template_name).to be_nil
    end
  end

  describe "#as_json" do
    it "carries the tiers and the derived template name" do
      expect(standard.as_json).to eq(
        "tiers" => [
          { "hours_before" => 168, "refund_percent" => 100 },
          { "hours_before" => 48,  "refund_percent" => 50 }
        ],
        "template_name" => "standard"
      )
    end
  end
end
