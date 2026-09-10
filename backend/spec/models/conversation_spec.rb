require "rails_helper"

RSpec.describe Conversation, type: :model do
  let(:user) { create(:user) }

  describe "validations" do
    it { is_expected.to belong_to(:user) }
    it { is_expected.to belong_to(:assigned_admin).optional }

    it "rejects an unknown status" do
      expect(build(:conversation, status: "escalated")).not_to be_valid
    end
  end

  # The rule the partial unique index enforces: one live thread per person, but
  # resolving it must let them ask something else. Getting only half of this
  # right is how the registrations bug happened.
  describe "one live conversation per participant" do
    it "rejects a second live conversation" do
      create(:conversation, user: user)

      expect(build(:conversation, user: user)).not_to be_valid
    end

    it "counts a pending conversation as live — it's still their open thread" do
      create(:conversation, :pending, user: user)

      expect(build(:conversation, user: user)).not_to be_valid
    end

    it "allows a new one once the previous is resolved" do
      create(:conversation, :resolved, user: user)

      expect(build(:conversation, user: user)).to be_valid
    end

    it "allows any number of resolved conversations" do
      create_list(:conversation, 3, :resolved, user: user)

      expect(build(:conversation, :resolved, user: user)).to be_valid
    end

    it "does not constrain a different participant" do
      create(:conversation, user: user)

      expect(build(:conversation, user: create(:user))).to be_valid
    end

    # The validation and the index have to agree, so prove the database would
    # have caught it too — a model-only rule silently stops applying the moment
    # anything writes around Active Record's validations.
    #
    # insert_all! with the bang, deliberately: plain `insert_all` compiles to
    # INSERT ... ON CONFLICT DO NOTHING, so it swallows exactly the violation
    # this example exists to observe and passes while proving nothing.
    it "is enforced by the database as well" do
      create(:conversation, user: user)

      expect {
        described_class.insert_all!([ {
          user_id: user.id, status: described_class::OPEN,
          created_at: Time.current, updated_at: Time.current
        } ])
      }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe "read state" do
    let(:conversation) { create(:conversation, user: user) }

    it "is not unread for either side when empty" do
      expect(conversation).not_to be_unread_for_participant
      expect(conversation).not_to be_unread_for_staff
    end

    # The reason read state isn't just `last_message_at` vs a timestamp: your
    # own message is the newest one in the thread, and must not light up your
    # own badge.
    it "does not mark the participant unread for their own message" do
      create(:message, conversation: conversation, sender: user)

      expect(conversation.reload).not_to be_unread_for_participant
      expect(conversation).to be_unread_for_staff
    end

    it "does not mark staff unread for a staff reply" do
      create(:message, :from_staff, conversation: conversation)

      expect(conversation.reload).not_to be_unread_for_staff
      expect(conversation).to be_unread_for_participant
    end

    it "clears once that side reads it" do
      create(:message, conversation: conversation, sender: user)

      conversation.mark_read_for_staff!

      expect(conversation).not_to be_unread_for_staff
    end

    it "goes unread again on the next message from the other side" do
      conversation.mark_read_for_staff!
      create(:message, conversation: conversation, sender: user, created_at: 1.minute.from_now)

      expect(conversation.reload).to be_unread_for_staff
    end
  end

  describe ".awaiting_staff" do
    it "returns live threads with participant messages staff haven't read" do
      waiting = create(:conversation, user: user)
      create(:message, conversation: waiting, sender: user)

      expect(described_class.awaiting_staff).to include(waiting)
    end

    it "excludes threads staff have already read" do
      seen = create(:conversation, user: user)
      create(:message, conversation: seen, sender: user)
      seen.mark_read_for_staff!

      expect(described_class.awaiting_staff).not_to include(seen)
    end

    it "excludes threads whose last word was ours" do
      answered = create(:conversation, user: user)
      create(:message, :from_staff, conversation: answered)

      expect(described_class.awaiting_staff).not_to include(answered)
    end

    it "excludes resolved threads even with unread participant messages" do
      closed = create(:conversation, :resolved, user: user)
      create(:message, conversation: closed, sender: closed.user)

      expect(described_class.awaiting_staff).not_to include(closed)
    end

    # A thread can be closed with the participant's last message still unread,
    # and an agent wants to see that — so the bare predicate must not carry
    # awaiting_staff's live constraint.
    it "is narrower than the bare unread predicate, which includes resolved threads" do
      closed = create(:conversation, :resolved, user: create(:user))
      create(:message, conversation: closed, sender: closed.user)

      expect(described_class.awaiting_staff).not_to include(closed)
      expect(described_class.with_unread_from_participant).to include(closed)
    end

    # Same result as the per-row predicate, computed in SQL. If these two ever
    # disagree the inbox and the thread view start contradicting each other.
    it "agrees with #unread_for_staff?" do
      create(:conversation, user: user).tap { |c| create(:message, conversation: c, sender: user) }
      create(:conversation, user: create(:user)).tap { |c| create(:message, :from_staff, conversation: c) }
      create(:conversation, user: create(:user))

      by_scope = described_class.awaiting_staff.to_a
      by_predicate = described_class.all.select { |c| c.live? && c.unread_for_staff? }

      expect(by_scope).to match_array(by_predicate)
    end
  end

  describe "#last_message_at" do
    it "is maintained as messages arrive, so the inbox can sort without a join" do
      conversation = create(:conversation, user: user)
      expect(conversation.last_message_at).to be_nil

      create(:message, conversation: conversation, sender: user)

      expect(conversation.reload.last_message_at).to be_present
    end
  end

  describe "cleanup" do
    it "goes away with the participant, messages and all" do
      conversation = create(:conversation, :with_exchange, user: user)

      expect { user.destroy }
        .to change(described_class, :count).by(-1)
        .and change(Message, :count).by(-2)
    end

    # The claim is a sticky note. Losing the admin who picked a thread up must
    # not lose the participant's conversation.
    it "survives the assigned admin being deleted" do
      conversation = create(:conversation, :assigned, user: user)
      admin = conversation.assigned_admin

      admin.destroy

      expect(conversation.reload.assigned_admin_id).to be_nil
    end
  end
end
