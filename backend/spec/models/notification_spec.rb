require "rails_helper"

RSpec.describe Notification, type: :model do
  let(:user) { create(:user) }

  describe "validations" do
    it { is_expected.to belong_to(:user) }
    it { is_expected.to belong_to(:event).optional }

    it "rejects an unknown kind" do
      expect(build(:notification, kind: "vibes")).not_to be_valid
    end

    it "requires a title" do
      expect(build(:notification, title: nil)).not_to be_valid
    end

    it "allows a notification not tied to an event" do
      expect(build(:notification, event: nil)).to be_valid
    end
  end

  describe "#mark_read!" do
    it "marks it read" do
      notification = create(:notification, user: user)

      notification.mark_read!

      expect(notification.reload).to be_read
      expect(described_class.unread).not_to include(notification)
    end

    # Otherwise "when did I see this" stops meaning anything.
    it "does not move the timestamp on a second call" do
      notification = create(:notification, user: user)
      notification.mark_read!
      first = notification.read_at

      notification.mark_read!

      expect(notification.reload.read_at).to be_within(0.001).of(first)
    end
  end

  describe ".badge_count_for" do
    it "counts only this user's unread" do
      create_list(:notification, 2, user: user)
      create(:notification, user: user, read_at: 1.hour.ago)
      create(:notification, user: create(:user))

      expect(described_class.badge_count_for(user)).to eq(2)
    end

    it "is zero for a user with nothing" do
      expect(described_class.badge_count_for(user)).to eq(0)
    end

    # A badge reading "99+" is as actionable as one reading "247", and the cap
    # is what keeps this query cheap for a user who never clears it.
    it "stops counting past the badge ceiling" do
      create_list(:notification, described_class::MAX_BADGE_COUNT + 5, user: user)

      expect(described_class.badge_count_for(user)).to eq(described_class::MAX_BADGE_COUNT + 1)
    end
  end

  describe "cleanup" do
    it "goes away with the user" do
      create(:notification, user: user)

      expect { user.destroy }.to change(described_class, :count).by(-1)
    end
  end
end
