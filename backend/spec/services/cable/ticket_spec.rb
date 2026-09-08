require "rails_helper"

RSpec.describe Cable::Ticket, :with_cache do
  let(:user) { create(:user) }

  describe ".issue / .redeem" do
    it "round-trips to the user who was issued it" do
      expect(described_class.redeem(described_class.issue(user))).to eq(user)
    end

    it "issues a different ticket every time" do
      expect(described_class.issue(user)).not_to eq(described_class.issue(user))
    end

    # The property that makes a ticket recovered from an access log worthless
    # rather than merely short-lived.
    it "cannot be redeemed twice" do
      ticket = described_class.issue(user)

      expect(described_class.redeem(ticket)).to eq(user)
      expect(described_class.redeem(ticket)).to be_nil
    end

    it "expires" do
      ticket = described_class.issue(user)

      travel(described_class::TTL + 1.second) do
        expect(described_class.redeem(ticket)).to be_nil
      end
    end

    # A dump of the cache table must not yield usable tickets — same reasoning
    # as storing password digests rather than passwords.
    it "stores only a digest, never the ticket itself" do
      ticket = described_class.issue(user)

      expect(Rails.cache.read("cable:ticket:#{ticket}")).to be_nil
      expect(Rails.cache.read("cable:ticket:#{Digest::SHA256.hexdigest(ticket)}")).to eq(user.id)
    end
  end

  describe ".redeem with bad input" do
    it "returns nil rather than raising" do
      expect(described_class.redeem("not-a-real-ticket")).to be_nil
      expect(described_class.redeem("")).to be_nil
      expect(described_class.redeem(nil)).to be_nil
    end

    # The ticket outlives the account only in the window between issue and
    # deletion, but the connection must not resurrect a deleted user.
    it "returns nil when the account has since been destroyed" do
      ticket = described_class.issue(user)
      user.destroy

      expect(described_class.redeem(ticket)).to be_nil
    end
  end
end
