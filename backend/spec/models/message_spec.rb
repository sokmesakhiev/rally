require "rails_helper"

RSpec.describe Message, type: :model do
  let(:participant) { create(:user) }
  let(:conversation) { create(:conversation, user: participant) }

  describe "validations" do
    it { is_expected.to belong_to(:conversation) }

    # Deliberately not `belong_to(:sender).optional`. That matcher asserts a
    # record with no sender is valid, and on create it isn't — the custom
    # sender_present_unless_system validation sees to that. `optional: true` is
    # there to suppress Rails' own *unconditional* presence check, so that a
    # message whose sender was nullified by ON DELETE SET NULL can still be
    # saved afterwards. The two examples below state that rule directly, and
    # "still saveable once orphaned" further down proves the part `optional:`
    # actually buys.

    it "requires a body" do
      expect(build(:message, conversation: conversation, body: " ")).not_to be_valid
    end

    it "caps the body length" do
      too_long = build(:message, conversation: conversation, body: "x" * (described_class::MAX_BODY_LENGTH + 1))

      expect(too_long).not_to be_valid
    end

    it "rejects an unknown sender role" do
      expect(build(:message, conversation: conversation, sender_role: "moderator")).not_to be_valid
    end

    it "requires a sender unless the message is from the system" do
      expect(build(:message, conversation: conversation, sender: nil, sender_role: described_class::STAFF))
        .not_to be_valid
    end

    it "allows a system message with no sender" do
      expect(build(:message, :from_system, conversation: conversation)).to be_valid
    end
  end

  # Derived from position in the thread, not from users.admin — an admin who
  # opens their own support thread is the participant in it.
  describe "sender_role derivation" do
    it "marks the conversation's owner as the participant" do
      message = create(:message, conversation: conversation, sender: participant)

      expect(message.sender_role).to eq(described_class::PARTICIPANT)
    end

    it "marks anyone else as staff" do
      message = create(:message, conversation: conversation, sender: create(:user, admin: true))

      expect(message.sender_role).to eq(described_class::STAFF)
    end

    it "calls an admin the participant in their own thread" do
      admin = create(:user, admin: true)
      own_thread = create(:conversation, user: admin)

      message = create(:message, conversation: own_thread, sender: admin)

      expect(message.sender_role).to eq(described_class::PARTICIPANT)
    end

    it "leaves an explicitly set role alone" do
      message = create(:message, :from_system, conversation: conversation)

      expect(message.sender_role).to eq(described_class::SYSTEM)
    end

    # The snapshot's whole purpose: history must not be rewritten by a later
    # change to who is staff.
    it "does not change when the sender loses their admin flag" do
      admin = create(:user, admin: true)
      message = create(:message, conversation: conversation, sender: admin)

      admin.update!(admin: false)
      message.update!(body: "edited")

      expect(message.reload.sender_role).to eq(described_class::STAFF)
    end
  end

  describe "when the sender's account is destroyed" do
    # A staff reply lives inside someone else's thread, so it has to outlive
    # the person who wrote it.
    it "keeps the message and nullifies the sender" do
      admin = create(:user, admin: true)
      message = create(:message, conversation: conversation, sender: admin)

      expect { admin.destroy }.not_to change(described_class, :count)
      expect(message.reload.sender_id).to be_nil
      expect(message.sender_role).to eq(described_class::STAFF)
      expect(message).to be_orphaned_sender
    end

    # What `optional: true` on the association is actually for. Rails' default
    # belongs_to presence check is unconditional, so without it an orphaned
    # message could never be saved again — and the sender_present_unless_system
    # validation is scoped `on: :create` for the same reason.
    it "leaves the orphaned message saveable" do
      admin = create(:user, admin: true)
      message = create(:message, conversation: conversation, sender: admin)
      admin.destroy

      message.reload

      expect(message).to be_valid
      expect { message.update!(body: "still editable") }.not_to raise_error
    end
  end

  describe ".after_id" do
    let!(:first)  { create(:message, conversation: conversation, sender: participant, created_at: 3.minutes.ago) }
    let!(:second) { create(:message, conversation: conversation, sender: participant, created_at: 2.minutes.ago) }
    let!(:third)  { create(:message, conversation: conversation, sender: participant, created_at: 1.minute.ago) }

    it "returns only what came after the cursor" do
      expect(conversation.messages.after_id(first.id)).to eq([ second, third ])
    end

    it "returns nothing when the cursor is the newest message" do
      expect(conversation.messages.after_id(third.id)).to be_empty
    end

    it "returns the whole thread with no cursor" do
      expect(conversation.messages.after_id(nil)).to eq([ first, second, third ])
    end

    # A client whose cursor we can't place gets a full resync. Returning
    # nothing would look like an empty conversation, which is worse.
    it "returns the whole thread for an unrecognised cursor" do
      expect(conversation.messages.after_id(SecureRandom.uuid)).to eq([ first, second, third ])
    end

    # Timestamps collide more often than people expect, especially when a
    # broadcast and a write land in the same transaction. Comparing created_at
    # alone would silently drop one of these forever.
    it "does not drop messages sharing a timestamp" do
      same_time = 30.seconds.ago
      a = create(:message, conversation: conversation, sender: participant, created_at: same_time)
      b = create(:message, conversation: conversation, sender: participant, created_at: same_time)

      # Deliberately not asserting which of the two sorts first — that's the
      # database's business. The bug this guards against is `created_at >`
      # alone, where *neither* is strictly greater than the other, so each one
      # used as a cursor hides the other and one message is lost for good.
      # Exactly one direction must find the other.
      reachable_from_a = conversation.messages.after_id(a.id).include?(b)
      reachable_from_b = conversation.messages.after_id(b.id).include?(a)

      expect([ reachable_from_a, reachable_from_b ]).to contain_exactly(true, false)
    end
  end
end
