require "rails_helper"

RSpec.describe Conversations::Resolve do
  let(:participant) { create(:user) }
  let(:conversation) { create(:conversation, user: participant) }

  it "closes the thread and reports that it changed something" do
    expect(described_class.call(conversation: conversation)).to be(true)
    expect(conversation.reload.status).to eq(Conversation::RESOLVED)
  end

  # Resolving frees the participant's one live slot, so their next message
  # starts a *new* thread. Without a visible marker that reads as their history
  # disappearing.
  it "leaves a system message explaining what happened" do
    described_class.call(conversation: conversation)

    note = conversation.messages.last
    expect(note.sender_role).to eq(Message::SYSTEM)
    expect(note.sender).to be_nil
    expect(note.body).to eq(described_class::RESOLVED_NOTICE)
  end

  # The system note runs through the same messages association as a real reply,
  # and PostMessage's status rule would flip a live thread to "pending" —
  # putting a conversation the agent just closed straight back in front of
  # them. Writing the status first is what prevents that.
  it "stays resolved despite the note being written after" do
    described_class.call(conversation: conversation)

    expect(conversation.reload.status).to eq(Conversation::RESOLVED)
  end

  it "is idempotent" do
    described_class.call(conversation: conversation)

    expect { described_class.call(conversation: conversation) }.not_to change(Message, :count)
    expect(described_class.call(conversation: conversation)).to be(false)
  end

  it "frees the participant to open a new thread" do
    described_class.call(conversation: conversation)

    expect(build(:conversation, user: participant)).to be_valid
  end
end
