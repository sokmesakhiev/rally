require "rails_helper"

RSpec.describe "Support chat (participant)", type: :request do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }

  describe "GET /api/v1/support/conversation" do
    it "requires a session" do
      get "/api/v1/support/conversation"

      expect(response).to have_http_status(:unauthorized)
    end

    # Having no support thread is the normal state for almost everyone, so it
    # must not look like an error — the launcher polls this for its badge.
    it "returns null when there is no thread, not a 404" do
      get "/api/v1/support/conversation", headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["conversation"]).to be_nil
    end

    it "returns the caller's live thread with an unread count" do
      conversation = create(:conversation, user: user)
      create(:message, :from_staff, conversation: conversation)

      get "/api/v1/support/conversation", headers: auth_headers(user)

      body = response.parsed_body["conversation"]
      expect(body["id"]).to eq(conversation.id)
      expect(body["status"]).to eq(Conversation::OPEN)
      expect(body["unread_count"]).to eq(1)
    end

    it "does not count the participant's own messages as unread" do
      conversation = create(:conversation, user: user)
      create(:message, conversation: conversation, sender: user)

      get "/api/v1/support/conversation", headers: auth_headers(user)

      expect(response.parsed_body["conversation"]["unread_count"]).to eq(0)
    end

    it "never returns another user's thread" do
      create(:conversation, user: other_user)

      get "/api/v1/support/conversation", headers: auth_headers(user)

      expect(response.parsed_body["conversation"]).to be_nil
    end

    it "returns null once the thread is resolved" do
      create(:conversation, :resolved, user: user)

      get "/api/v1/support/conversation", headers: auth_headers(user)

      expect(response.parsed_body["conversation"]).to be_nil
    end
  end

  describe "POST /api/v1/support/conversation" do
    it "creates one and reports 201" do
      expect {
        post "/api/v1/support/conversation", headers: auth_headers(user)
      }.to change(Conversation, :count).by(1)

      expect(response).to have_http_status(:created)
    end

    # The widget calls this every time the panel opens.
    it "is idempotent, reporting 200 for a thread that already existed" do
      existing = create(:conversation, user: user)

      expect {
        post "/api/v1/support/conversation", headers: auth_headers(user)
      }.not_to change(Conversation, :count)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["conversation"]["id"]).to eq(existing.id)
    end

    it "accepts an optional subject" do
      post "/api/v1/support/conversation", params: { subject: "Refund question" },
                                           headers: auth_headers(user), as: :json

      expect(response.parsed_body["conversation"]["subject"]).to eq("Refund question")
    end

    it "rejects an over-long subject" do
      post "/api/v1/support/conversation", params: { subject: "x" * 500 },
                                           headers: auth_headers(user), as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to be_present
    end

    # The schema measures the stripped length, so a padded subject at the limit
    # passes validation. Persisting it raw would then blow the model's own
    # limit and 500 on input the boundary had just accepted.
    it "strips a subject padded to the limit rather than 500ing" do
      padded = "#{'x' * SupportConversationCreateRequestSchema::MAX_SUBJECT_LENGTH}     "

      post "/api/v1/support/conversation", params: { subject: padded },
                                           headers: auth_headers(user), as: :json

      expect(response).to have_http_status(:created)
      expect(response.parsed_body["conversation"]["subject"])
        .to eq("x" * SupportConversationCreateRequestSchema::MAX_SUBJECT_LENGTH)
    end

    it "treats a whitespace-only subject as absent" do
      post "/api/v1/support/conversation", params: { subject: "   " },
                                           headers: auth_headers(user), as: :json

      expect(response.parsed_body["conversation"]["subject"]).to be_nil
    end
  end

  describe "GET /api/v1/support/messages" do
    it "returns an empty list when there is no thread" do
      get "/api/v1/support/messages", headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("messages" => [], "conversation" => nil, "has_more" => false)
    end

    it "returns the thread oldest-first" do
      conversation = create(:conversation, user: user)
      create(:message, conversation: conversation, sender: user, body: "First", created_at: 2.hours.ago)
      create(:message, :from_staff, conversation: conversation, body: "Second", created_at: 1.hour.ago)

      get "/api/v1/support/messages", headers: auth_headers(user)

      expect(response.parsed_body["messages"].map { |m| m["body"] }).to eq(%w[First Second])
    end

    # No sender name on purpose — a participant needs to know which side spoke,
    # not which employee did.
    it "identifies the side without naming the agent" do
      conversation = create(:conversation, user: user)
      create(:message, :from_staff, conversation: conversation)

      get "/api/v1/support/messages", headers: auth_headers(user)

      message = response.parsed_body["messages"].first
      expect(message["sender_role"]).to eq(Message::STAFF)
      expect(message.keys).not_to include("sender_name")
      expect(message.keys).not_to include("sender_id")
    end

    it "caps the page and reports there is more" do
      conversation = create(:conversation, user: user)
      create_list(:message, Api::V1::Support::MessagesController::PAGE_SIZE + 5,
                  conversation: conversation, sender: user)

      get "/api/v1/support/messages", headers: auth_headers(user)

      expect(response.parsed_body["messages"].size)
        .to eq(Api::V1::Support::MessagesController::PAGE_SIZE)
      expect(response.parsed_body["has_more"]).to be(true)
    end

    # The reconnect catch-up. Every deploy severs every socket, so this is the
    # path that makes the WebSocket an optimisation rather than a guarantee.
    describe "?after=" do
      it "returns only what came after the cursor" do
        conversation = create(:conversation, user: user)
        first = create(:message, conversation: conversation, sender: user, created_at: 2.hours.ago)
        create(:message, :from_staff, conversation: conversation, body: "Missed this", created_at: 1.hour.ago)

        get "/api/v1/support/messages", params: { after: first.id }, headers: auth_headers(user)

        expect(response.parsed_body["messages"].map { |m| m["body"] }).to eq([ "Missed this" ])
      end

      it "returns nothing when the client is already up to date" do
        conversation = create(:conversation, user: user)
        latest = create(:message, conversation: conversation, sender: user)

        get "/api/v1/support/messages", params: { after: latest.id }, headers: auth_headers(user)

        expect(response.parsed_body["messages"]).to be_empty
      end
    end

    # Without this, has_more on a first page is a flag the client can see but
    # not act on, and a thread longer than one page has a beginning the
    # participant can never reach.
    describe "?before=" do
      let(:conversation) { create(:conversation, user: user) }
      let!(:messages) do
        (1..(Api::V1::Support::MessagesController::PAGE_SIZE + 10)).map do |i|
          create(:message, conversation: conversation, sender: user,
                           body: "Message #{i}", created_at: i.minutes.ago)
        end.reverse # oldest first
      end

      it "walks back to the start of a thread longer than one page" do
        get "/api/v1/support/messages", headers: auth_headers(user)
        first_page = response.parsed_body
        expect(first_page["has_more"]).to be(true)

        oldest_seen = first_page["messages"].first["id"]
        get "/api/v1/support/messages", params: { before: oldest_seen }, headers: auth_headers(user)
        second_page = response.parsed_body

        expect(second_page["messages"].size).to eq(10)
        expect(second_page["has_more"]).to be(false)
        expect(second_page["messages"].first["body"]).to eq(messages.first.body)
      end

      it "does not overlap with the page it came from" do
        get "/api/v1/support/messages", headers: auth_headers(user)
        first_ids = response.parsed_body["messages"].map { |m| m["id"] }

        get "/api/v1/support/messages", params: { before: first_ids.first }, headers: auth_headers(user)
        second_ids = response.parsed_body["messages"].map { |m| m["id"] }

        expect(second_ids & first_ids).to be_empty
      end

      # Unlike `after`, an unplaceable cursor must not fall back to the newest
      # page — that would be an infinite scroll that never advances.
      it "returns nothing for an unrecognised cursor" do
        get "/api/v1/support/messages", params: { before: SecureRandom.uuid },
                                        headers: auth_headers(user)

        expect(response.parsed_body["messages"]).to be_empty
      end

      it "ignores before when after is also given" do
        get "/api/v1/support/messages",
            params: { after: messages.first.id, before: messages.last.id },
            headers: auth_headers(user)

        expect(response.parsed_body["messages"]).not_to be_empty
        expect(response.parsed_body["messages"].first["body"]).to eq(messages.second.body)
      end
    end
  end

  describe "POST /api/v1/support/messages" do
    it "starts a thread when there isn't one, so the first message just works" do
      expect {
        post "/api/v1/support/messages", params: { body: "Hello?" },
                                         headers: auth_headers(user), as: :json
      }.to change(Conversation, :count).by(1).and change(Message, :count).by(1)

      expect(response).to have_http_status(:created)
      expect(response.parsed_body["message"]["sender_role"]).to eq(Message::PARTICIPANT)
    end

    it "posts into the existing thread" do
      conversation = create(:conversation, user: user)

      expect {
        post "/api/v1/support/messages", params: { body: "Any update?" },
                                         headers: auth_headers(user), as: :json
      }.not_to change(Conversation, :count)

      expect(conversation.messages.count).to eq(1)
    end

    # A participant replying is a question for us: back into the inbox.
    it "flips a pending thread back to open" do
      conversation = create(:conversation, :pending, user: user)

      post "/api/v1/support/messages", params: { body: "Still stuck" },
                                       headers: auth_headers(user), as: :json

      expect(conversation.reload.status).to eq(Conversation::OPEN)
      expect(Conversation.awaiting_staff).to include(conversation)
    end

    it "rejects a blank body" do
      post "/api/v1/support/messages", params: { body: "   " },
                                       headers: auth_headers(user), as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(Message.count).to eq(0)
    end

    it "rejects a body past the cap" do
      post "/api/v1/support/messages", params: { body: "x" * (Message::MAX_BODY_LENGTH + 1) },
                                       headers: auth_headers(user), as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(Message.count).to eq(0)
    end

    it "requires a session" do
      post "/api/v1/support/messages", params: { body: "Hello?" }, as: :json

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "POST /api/v1/support/read" do
    it "clears the unread count" do
      conversation = create(:conversation, user: user)
      create(:message, :from_staff, conversation: conversation)

      post "/api/v1/support/read", headers: auth_headers(user)

      expect(response.parsed_body["conversation"]["unread_count"]).to eq(0)
      expect(conversation.reload).not_to be_unread_for_participant
    end

    it "is a no-op with no thread" do
      post "/api/v1/support/read", headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["conversation"]).to be_nil
    end

    # Reading your own thread must not mark it read for staff — that would
    # empty the inbox as a side effect of the participant opening the widget.
    it "does not touch the staff side" do
      conversation = create(:conversation, user: user)
      create(:message, conversation: conversation, sender: user)

      post "/api/v1/support/read", headers: auth_headers(user)

      expect(conversation.reload).to be_unread_for_staff
    end
  end
end
