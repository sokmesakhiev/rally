require "rails_helper"

RSpec.describe Conversations::PostMessage do
  let(:participant) { create(:user) }
  let(:admin) { create(:user, admin: true) }
  let(:conversation) { create(:conversation, user: participant) }

  def post_from(sender, body: "hello")
    described_class.call(conversation: conversation, sender: sender, body: body)
  end

  it "adds the message with the role derived from the thread" do
    expect { post_from(participant) }.to change(conversation.messages, :count).by(1)
    expect(conversation.messages.last.sender_role).to eq(Message::PARTICIPANT)

    post_from(admin)
    expect(conversation.messages.last.sender_role).to eq(Message::STAFF)
  end

  # A reply from one side is a question for the other.
  describe "status" do
    it "moves to open when the participant writes" do
      conversation.update!(status: Conversation::PENDING)

      post_from(participant)

      expect(conversation.reload.status).to eq(Conversation::OPEN)
    end

    it "moves to pending when staff writes" do
      post_from(admin)

      expect(conversation.reload.status).to eq(Conversation::PENDING)
    end

    # Reopening on a new message sounds helpful but would collide with the
    # one-live-thread index the moment the participant already started a fresh
    # conversation.
    it "leaves a resolved thread resolved" do
      conversation.update!(status: Conversation::RESOLVED)

      post_from(admin)

      expect(conversation.reload.status).to eq(Conversation::RESOLVED)
    end
  end

  # Without this, the sender's own message leaves their side showing unread —
  # for staff, a thread they just answered sitting in the inbox forever.
  describe "the sender's own read stamp" do
    it "does not leave staff unread after they reply" do
      post_from(admin)

      expect(conversation.reload).not_to be_unread_for_staff
      expect(Conversation.awaiting_staff).not_to include(conversation)
    end

    it "does not leave the participant unread after they write" do
      post_from(participant)

      expect(conversation.reload).not_to be_unread_for_participant
    end

    it "still marks the other side unread" do
      post_from(participant)

      expect(conversation.reload).to be_unread_for_staff
    end

    # created_at comes from the app server, not the database, so it isn't
    # guaranteed to be later than a stamp written moments ago by another ECS
    # task with a slightly different clock. A read stamp that moves backwards
    # makes already-seen messages unread again.
    it "never moves a read stamp backwards" do
      read_at = Time.current
      conversation.update!(staff_last_read_at: read_at)

      # A message whose created_at precedes the existing stamp — what clock
      # skew between two ECS tasks, or a backfill writing historical rows,
      # produces. Overwriting here would make already-seen messages unread.
      travel_to(read_at - 1.hour) { post_from(admin) }

      expect(conversation.reload.staff_last_read_at).to be_within(1.second).of(read_at)
    end
  end

  it "keeps last_message_at current so the inbox can sort" do
    post_from(participant)

    expect(conversation.reload.last_message_at).to be_present
  end

  it "rejects a body past the model cap" do
    expect { post_from(participant, body: "x" * (Message::MAX_BODY_LENGTH + 1)) }
      .to raise_error(ActiveRecord::RecordInvalid)
  end
end
