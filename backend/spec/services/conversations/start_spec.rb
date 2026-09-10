require "rails_helper"

RSpec.describe Conversations::Start do
  let(:user) { create(:user) }

  it "creates a thread for someone who has none" do
    result = described_class.call(user: user)

    expect(result.created).to be(true)
    expect(result.conversation.user).to eq(user)
    expect(result.conversation.status).to eq(Conversation::OPEN)
  end

  it "returns the existing live thread instead of a second one" do
    existing = create(:conversation, user: user)

    result = nil
    expect { result = described_class.call(user: user) }.not_to change(Conversation, :count)
    expect(result.conversation).to eq(existing)
    expect(result.created).to be(false)
  end

  it "treats a pending thread as the live one" do
    existing = create(:conversation, :pending, user: user)

    expect(described_class.call(user: user).conversation).to eq(existing)
  end

  it "starts a fresh thread once the previous is resolved" do
    create(:conversation, :resolved, user: user)

    result = described_class.call(user: user)

    expect(result.created).to be(true)
    expect(user.conversations.count).to eq(2)
  end

  it "records an optional subject" do
    result = described_class.call(user: user, subject: "Refund question")

    expect(result.conversation.subject).to eq("Refund question")
  end

  # The two ways the one-live-thread rule can fire, depending on whether the
  # uniqueness validation's own SELECT saw the other row or the index did.
  # Both have to resolve to "here's your thread" — a double-tapped launcher
  # must not 500.
  describe "when it loses the race" do
    it "returns the winner's thread when the validation catches it" do
      winner = create(:conversation, user: user)
      # Simulates the validation seeing the row: create! raises RecordInvalid
      # with a :taken error, exactly as it would under concurrency.
      allow(Conversation).to receive(:create!).and_wrap_original do |_original, *_args|
        record = Conversation.new(user: user)
        record.errors.add(:user_id, :taken)
        raise ActiveRecord::RecordInvalid, record
      end

      result = described_class.call(user: user)

      expect(result.conversation).to eq(winner)
      expect(result.created).to be(false)
    end

    it "returns the winner's thread when only the index catches it" do
      winner = create(:conversation, user: user)
      allow(Conversation).to receive(:create!).and_raise(ActiveRecord::RecordNotUnique, "duplicate key")

      result = described_class.call(user: user)

      expect(result.conversation).to eq(winner)
      expect(result.created).to be(false)
    end
  end

  # A validation failure that isn't the race is this caller's own problem and
  # must surface, not be silently converted into someone else's conversation.
  it "re-raises a validation error unrelated to the race" do
    expect {
      described_class.call(user: user, subject: "x" * 500)
    }.to raise_error(ActiveRecord::RecordInvalid)
  end

  # Ticket C and D will plausibly call this from inside a transaction. Without
  # the savepoint around the INSERT, a unique violation aborts that outer
  # transaction, and the rescue's own follow-up SELECT then fails with
  # PG::InFailedSqlTransaction instead of recovering — a 500 that only ever
  # appears under concurrency, and only for those callers.
  it "recovers from the race even when called inside a transaction" do
    winner = create(:conversation, user: user)

    # Suppressing the uniqueness validator is what makes this a real test
    # rather than a tautology: the INSERT then actually reaches the partial
    # unique index and Postgres actually raises, which is the only way the
    # enclosing transaction gets aborted. Stubbing create! to raise
    # RecordNotUnique would produce no SQL error at all, and would pass
    # identically with or without the savepoint.
    allow_any_instance_of(ActiveRecord::Validations::UniquenessValidator)
      .to receive(:validate_each)

    result = nil
    expect {
      ActiveRecord::Base.transaction do
        result = described_class.call(user: user)
        # The outer transaction has to still be usable afterwards — this is
        # the statement that raises PG::InFailedSqlTransaction without it.
        Conversation.count
      end
    }.not_to raise_error

    expect(result.conversation).to eq(winner)
    expect(result.created).to be(false)
  end
end
