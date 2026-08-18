require "rails_helper"

RSpec.describe AdminAction, type: :model do
  let(:admin) { create(:user, admin: true) }
  let(:event) { create(:event) }

  describe "associations" do
    it { is_expected.to belong_to(:admin).class_name("User") }
    it { is_expected.to belong_to(:target) }
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:action) }
  end

  describe ".log!" do
    it "creates a queryable row and logs a matching line" do
      expect(Rails.logger).to receive(:info).with(
        "[admin] actor=#{admin.id} action=destroy_event target=Event##{event.id}"
      )

      action = AdminAction.log!(admin: admin, action: "destroy_event", target: event)

      expect(action).to be_persisted
      expect(action.admin).to eq(admin)
      expect(action.target).to eq(event)
      expect(action.action).to eq("destroy_event")
    end
  end

  describe "scopes" do
    it ".recent orders newest first" do
      older = create(:admin_action, admin: admin, target: event, created_at: 1.day.ago)
      newer = create(:admin_action, admin: admin, target: event)

      expect(AdminAction.recent.to_a).to eq([ newer, older ])
    end

    it ".for_action filters by action, .for_admin filters by admin_id" do
      other_admin = create(:user, admin: true)
      unpublish = create(:admin_action, admin: admin, action: "unpublish_event", target: event)
      create(:admin_action, admin: other_admin, action: "destroy_event", target: event)

      expect(AdminAction.for_action("unpublish_event")).to eq([ unpublish ])
      expect(AdminAction.for_admin(admin.id)).to eq([ unpublish ])
    end
  end
end
