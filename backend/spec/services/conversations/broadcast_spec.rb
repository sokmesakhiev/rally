require "rails_helper"

RSpec.describe Conversations::Broadcast do
  let(:participant) { create(:user) }
  let(:admin) { create(:user, admin: true) }
  let(:conversation) { create(:conversation, user: participant) }

  def participant_stream = ChatChannel.stream_name_for(participant.id)

  describe "posting a message" do
    it "reaches the participant's own stream" do
      expect {
        Conversations::PostMessage.call(conversation: conversation, sender: admin, body: "Looking into it")
      }.to have_broadcasted_to(participant_stream).with { |data|
        expect(data[:type]).to eq(described_class::EVENT)
        expect(data[:message][:body]).to eq("Looking into it")
      }
    end

    it "reaches the staff inbox" do
      expect {
        Conversations::PostMessage.call(conversation: conversation, sender: participant, body: "Help")
      }.to have_broadcasted_to(SupportInboxChannel::STREAM)
    end

    # The participant payload must never name the employee who replied; the
    # staff payload must. Same event, two audiences.
    it "sends audience-appropriate payloads" do
      captured = {}
      allow(ActionCable.server).to receive(:broadcast) { |stream, data| captured[stream] = data }

      Conversations::PostMessage.call(conversation: conversation, sender: admin, body: "Hello")

      expect(captured[participant_stream][:message]).not_to have_key(:sender_name)
      expect(captured[SupportInboxChannel::STREAM][:message][:sender_name]).to be_present
    end

    # Shapes come from the same module the REST endpoints use, so a client
    # merging live and fetched messages into one list can't see them differ.
    it "matches the REST payload shape" do
      captured = nil
      allow(ActionCable.server).to receive(:broadcast) { |stream, data| captured = data if stream == participant_stream }

      message = Conversations::PostMessage.call(conversation: conversation, sender: participant, body: "Hi")

      expect(captured[:message]).to eq(Support::Serializers.participant_message(message))
    end
  end

  # The reason this goes through after_all_transactions_commit rather than
  # simply running after the lock block: a caller that wraps the write in its
  # own transaction would otherwise have already told every client about a
  # message that ends up not existing.
  describe "when the surrounding transaction rolls back" do
    it "broadcasts nothing" do
      expect {
        begin
          ActiveRecord::Base.transaction do
            Conversations::PostMessage.call(conversation: conversation, sender: participant, body: "Doomed")
            raise ActiveRecord::Rollback
          end
        end
      }.not_to have_broadcasted_to(participant_stream)
    end
  end

  describe "resolving" do
    it "pushes the system notice with the conversation's new status" do
      expect {
        Conversations::Resolve.call(conversation: conversation)
      }.to have_broadcasted_to(participant_stream).with { |data|
        expect(data[:message][:sender_role]).to eq(Message::SYSTEM)
        expect(data[:conversation][:status]).to eq(Conversation::RESOLVED)
      }
    end

    it "stays quiet on an already-resolved thread" do
      Conversations::Resolve.call(conversation: conversation)

      expect { Conversations::Resolve.call(conversation: conversation) }
        .not_to have_broadcasted_to(participant_stream)
    end
  end

  # The socket is an optimisation; REST is the source of truth. A push that
  # fails must not take the committed write down with it.
  describe "when broadcasting fails" do
    before do
      allow(ActionCable.server).to receive(:broadcast).and_raise(StandardError, "cable down")
    end

    it "does not raise, and the message is still saved" do
      message = nil

      expect {
        message = Conversations::PostMessage.call(conversation: conversation, sender: participant, body: "Kept")
      }.not_to raise_error

      expect(message.reload.body).to eq("Kept")
    end
  end
end
