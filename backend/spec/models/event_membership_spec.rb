require "rails_helper"

RSpec.describe EventMembership, type: :model do
  let(:owner) { create(:user) }
  let(:event) { create(:event, creator: owner) }

  describe "associations" do
    it { is_expected.to belong_to(:event) }
    it { is_expected.to belong_to(:user) }
    it { is_expected.to belong_to(:invited_by).class_name("User").optional }
  end

  describe "validations" do
    subject { build(:event_membership) }

    it { is_expected.to validate_presence_of(:role) }
    it { is_expected.to validate_inclusion_of(:role).in_array(EventMembership::ROLES) }

    it "allows only one membership per user per event" do
      member = create(:user)
      create(:event_membership, event: event, user: member)

      duplicate = build(:event_membership, event: event, user: member)

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:user_id]).to include("is already a member of this event")
    end

    it "allows the same user on different events" do
      member = create(:user)
      create(:event_membership, event: event, user: member)

      expect(build(:event_membership, user: member)).to be_valid
    end

    it "allows different users on the same event" do
      create(:event_membership, event: event)

      expect(build(:event_membership, event: event)).to be_valid
    end
  end

  describe "role predicates" do
    it "answers for the role it holds and denies the others" do
      membership = build(:event_membership, :check_in)

      expect(membership.check_in?).to be(true)
      expect(membership.manager?).to be(false)
      expect(membership.viewer?).to be(false)
    end
  end

  describe ".managers" do
    it "returns only manager memberships" do
      manager = create(:event_membership, :manager, event: event)
      create(:event_membership, :viewer, event: event)

      expect(event.event_memberships.managers.to_a).to eq([ manager ])
    end
  end

  describe "event and user associations" do
    it "exposes members through the event" do
      member = create(:user)
      create(:event_membership, event: event, user: member)

      expect(event.reload.members).to include(member)
    end

    it "exposes member_events through the user, separately from owned events" do
      member = create(:user)
      own_event = create(:event, creator: member)
      create(:event_membership, event: event, user: member)

      expect(member.reload.member_events).to eq([ event ])
      expect(member.events).to eq([ own_event ])
    end
  end

  describe "Event#discard!" do
    it "leaves memberships intact so a restored event keeps its team" do
      create(:event_membership, event: event)

      expect { event.discard! }.not_to change(described_class, :count)
      expect(event.reload.event_memberships).not_to be_empty
    end
  end
end
