require "rails_helper"

RSpec.describe EventActivity, type: :model do
  let(:organizer) { create(:user) }
  let(:event) { create(:event, creator: organizer) }

  describe "associations" do
    it { is_expected.to belong_to(:event) }
    it { is_expected.to belong_to(:actor).class_name("User") }
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:action) }
    it { is_expected.to validate_inclusion_of(:action).in_array(EventActivity::ACTIONS) }
  end

  describe ".log!" do
    it "creates a queryable row" do
      activity = EventActivity.log!(
        event: event, actor: organizer, action: "remove_participant", metadata: { "participant_name" => "Dara Kim" }
      )

      expect(activity).to be_persisted
      expect(activity.event).to eq(event)
      expect(activity.actor).to eq(organizer)
      expect(activity.action).to eq("remove_participant")
      expect(activity.metadata).to eq("participant_name" => "Dara Kim")
    end

    it "defaults metadata to an empty hash" do
      activity = EventActivity.log!(event: event, actor: organizer, action: "update_event_details")

      expect(activity.metadata).to eq({})
    end
  end

  describe "scopes" do
    it ".recent orders newest first" do
      older = create(:event_activity, event: event, actor: organizer, created_at: 1.day.ago)
      newer = create(:event_activity, event: event, actor: organizer)

      expect(EventActivity.recent.to_a).to eq([ newer, older ])
    end
  end
end
