require "rails_helper"

RSpec.describe Conversations::SweepResolved do
  def resolved_conversation(resolved_at:, messages: 1)
    conversation = create(:conversation, status: Conversation::RESOLVED, resolved_at: resolved_at)
    messages.times { create(:message, conversation: conversation) }
    conversation
  end

  describe "what it destroys" do
    it "purges a thread resolved longer ago than the retention period" do
      old = resolved_conversation(resolved_at: (Conversation::RETENTION_PERIOD + 1.day).ago)

      expect { described_class.call }.to change(Conversation, :count).by(-1)
      expect(Conversation.where(id: old.id)).to be_empty
    end

    it "keeps a thread resolved inside the window" do
      recent = resolved_conversation(resolved_at: (Conversation::RETENTION_PERIOD - 1.day).ago)

      described_class.call

      expect(recent.reload).to be_persisted
    end

    # An unresolved thread is still someone's open question, however old.
    # Deleting it would answer them by making the question disappear.
    it "never touches a live thread, no matter how old" do
      live = create(:conversation, status: Conversation::OPEN, created_at: 5.years.ago)

      described_class.call

      expect(live.reload).to be_persisted
    end

    # An irreversible operation shouldn't run on a guess. The migration
    # backfills existing rows precisely so this isn't exempting real data.
    it "skips a resolved thread with no resolved_at recorded" do
      unknown = create(:conversation, status: Conversation::RESOLVED, resolved_at: nil,
                                      created_at: 5.years.ago)

      described_class.call

      expect(unknown.reload).to be_persisted
    end

    it "takes the messages with it" do
      resolved_conversation(resolved_at: 2.years.ago, messages: 3)

      expect { described_class.call }.to change(Message, :count).by(-3)
    end
  end

  describe "what it reports" do
    it "counts both threads and messages" do
      resolved_conversation(resolved_at: 2.years.ago, messages: 2)
      resolved_conversation(resolved_at: 2.years.ago, messages: 3)

      result = described_class.call

      expect(result.conversations).to eq(2)
      expect(result.messages).to eq(5)
    end

    it "reports zero when there is nothing to purge" do
      result = described_class.call

      expect(result.conversations).to eq(0)
      expect(result.messages).to eq(0)
    end
  end

  describe "MAX_PER_RUN" do
    # The backfill makes every historically-resolved thread eligible at once,
    # and destroying cascades to messages — so the first runs would otherwise
    # be one very long transaction on the worker.
    it "caps a single run" do
      stub_const("#{described_class}::MAX_PER_RUN", 1)
      2.times { resolved_conversation(resolved_at: 2.years.ago) }

      expect { described_class.call }.to change(Conversation, :count).by(-1)
    end

    it "drains the remainder on the next run" do
      stub_const("#{described_class}::MAX_PER_RUN", 1)
      2.times { resolved_conversation(resolved_at: 2.years.ago) }

      described_class.call

      expect { described_class.call }.to change(Conversation, :count).by(-1)
    end
  end

  # Retention that silently stops running because of one bad row is the
  # failure mode worth designing against: nobody notices data *not* being
  # deleted.
  it "keeps going when one thread can't be destroyed" do
    2.times { resolved_conversation(resolved_at: 2.years.ago) }

    # Fail the first destroy only. Counting calls rather than matching on an
    # id, because the sweep loads its own instances from the scope — the
    # objects created above are not the ones it operates on.
    calls = 0
    allow_any_instance_of(Conversation).to receive(:destroy!).and_wrap_original do |original|
      calls += 1
      raise "boom" if calls == 1

      original.call
    end

    expect(described_class.call.conversations).to eq(1)
    expect(Conversation.count).to eq(1)
  end
end
