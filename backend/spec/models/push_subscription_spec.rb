require "rails_helper"

RSpec.describe PushSubscription, type: :model do
  subject(:subscription) { build(:push_subscription) }

  describe "validations" do
    it { is_expected.to belong_to(:user) }
    it { is_expected.to validate_presence_of(:endpoint) }
    it { is_expected.to validate_presence_of(:p256dh_key) }
    it { is_expected.to validate_presence_of(:auth_key) }

    # Endpoint uniqueness is what makes re-subscribing idempotent. Without it,
    # a browser that subscribes twice gets two rows and the user gets every
    # notification twice.
    it "rejects a duplicate endpoint" do
      existing = create(:push_subscription)

      expect(build(:push_subscription, endpoint: existing.endpoint)).not_to be_valid
    end

    it "allows the same user several devices" do
      user = create(:user)
      create(:push_subscription, user: user)

      expect(build(:push_subscription, user: user)).to be_valid
    end
  end

  describe "#expire!" do
    it "marks the subscription dead and drops it out of .active" do
      subscription = create(:push_subscription)

      subscription.expire!

      expect(subscription).to be_expired
      expect(described_class.active).not_to include(subscription)
      expect(described_class.expired).to include(subscription)
    end

    # Kept rather than deleted, so "why did my phone stop getting these" is
    # answerable later.
    it "keeps the row" do
      subscription = create(:push_subscription)

      expect { subscription.expire! }.not_to change(described_class, :count)
    end

    it "is idempotent and doesn't move the timestamp on a second call" do
      subscription = create(:push_subscription)
      subscription.expire!
      first = subscription.expired_at

      subscription.expire!

      expect(subscription.reload.expired_at).to be_within(0.001).of(first)
    end
  end

  describe "cleanup" do
    it "goes away with the user — a delivery address, not a record to keep" do
      user = create(:user)
      create(:push_subscription, user: user)

      expect { user.destroy }.to change(described_class, :count).by(-1)
    end
  end
end
