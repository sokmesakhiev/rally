require "rails_helper"

RSpec.describe "Admin support conversations", type: :request do
  let(:admin) { create(:user, admin: true) }
  let(:other_admin) { create(:user, admin: true) }
  let(:participant) { create(:user) }
  let!(:conversation) { create(:conversation, user: participant) }

  # require_admin! renders 404 rather than 403 so the surface doesn't advertise
  # itself to non-admins. Checked once here for every route rather than
  # repeated per action.
  describe "access" do
    it "is unreachable without a session" do
      get "/api/v1/admin/conversations"

      expect(response).to have_http_status(:unauthorized)
    end

    it "is invisible to a non-admin" do
      get "/api/v1/admin/conversations", headers: auth_headers(participant)

      expect(response).to have_http_status(:not_found)
    end

    it "does not let a participant read a thread through the admin route" do
      get "/api/v1/admin/conversations/#{conversation.id}", headers: auth_headers(participant)

      expect(response).to have_http_status(:not_found)
    end

    it "404s an unknown id rather than 500ing" do
      get "/api/v1/admin/conversations/#{SecureRandom.uuid}", headers: auth_headers(admin)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /api/v1/admin/conversations" do
    it "lists threads with an unread flag and an awaiting count" do
      create(:message, conversation: conversation, sender: participant)

      get "/api/v1/admin/conversations", headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["conversations"].first["unread"]).to be(true)
      expect(body["conversations"].first["participant"]["email"]).to eq(participant.email)
      expect(body["awaiting_count"]).to eq(1)
    end

    # The rendered flag and the filter share one SQL predicate precisely so
    # they can't disagree — a thread shown as unread must also be one the
    # unread filter returns.
    it "agrees between the unread flag and the unread filter" do
      create(:message, conversation: conversation, sender: participant)
      quiet = create(:conversation, user: create(:user))
      create(:message, :from_staff, conversation: quiet)

      get "/api/v1/admin/conversations", params: { unread: true }, headers: auth_headers(admin)
      filtered = response.parsed_body["conversations"]

      expect(filtered.map { |c| c["id"] }).to eq([ conversation.id ])
      expect(filtered).to all(include("unread" => true))
    end

    it "filters by status" do
      resolved = create(:conversation, :resolved, user: create(:user))

      get "/api/v1/admin/conversations", params: { status: "resolved" }, headers: auth_headers(admin)

      expect(response.parsed_body["conversations"].map { |c| c["id"] }).to eq([ resolved.id ])
    end

    it "filters to threads this admin has claimed" do
      mine = create(:conversation, user: create(:user), assigned_admin: admin)
      create(:conversation, user: create(:user), assigned_admin: other_admin)

      get "/api/v1/admin/conversations", params: { assignment: "mine" }, headers: auth_headers(admin)

      expect(response.parsed_body["conversations"].map { |c| c["id"] }).to eq([ mine.id ])
    end

    it "filters to unclaimed threads" do
      create(:conversation, user: create(:user), assigned_admin: admin)

      get "/api/v1/admin/conversations", params: { assignment: "unassigned" }, headers: auth_headers(admin)

      expect(response.parsed_body["conversations"].map { |c| c["id"] }).to eq([ conversation.id ])
    end

    # status and unread have to compose rather than one silently overriding the
    # other, which merging the awaiting_staff scope would have done.
    it "combines status and unread without one overriding the other" do
      resolved = create(:conversation, :resolved, user: create(:user))
      create(:message, conversation: resolved, sender: resolved.user)

      get "/api/v1/admin/conversations", params: { status: "resolved", unread: true },
                                         headers: auth_headers(admin)

      expect(response.parsed_body["conversations"].map { |c| c["id"] }).to eq([ resolved.id ])
    end

    it "rejects an unknown status" do
      get "/api/v1/admin/conversations", params: { status: "escalated" }, headers: auth_headers(admin)

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe "GET /api/v1/admin/conversations/:id" do
    it "returns the thread with the participant's Rally context" do
      event = create(:event, title: "Angkor Half Marathon")
      create(:registration, :paid, user: participant, event: event)
      create(:message, conversation: conversation, sender: participant, body: "Where's my ticket?")

      get "/api/v1/admin/conversations/#{conversation.id}", headers: auth_headers(admin)

      body = response.parsed_body
      expect(body["messages"].first["body"]).to eq("Where's my ticket?")
      registration = body["participant"]["registrations"].first
      expect(registration["event_title"]).to eq("Angkor Half Marathon")
      expect(registration["payment_status"]).to eq("paid")
      expect(registration["amount_paid_cents"]).to eq(2500)
    end

    # Unlike the participant serializer, this one names the colleague who
    # replied — everyone reading it is already staff.
    it "names the staff sender" do
      create(:message, conversation: conversation, sender: admin)

      get "/api/v1/admin/conversations/#{conversation.id}", headers: auth_headers(admin)

      expect(response.parsed_body["messages"].first["sender_name"]).to be_present
    end

    # Naming the sender means dereferencing sender and profile per message.
    # Without preloading, a full page walks both per row — up to 200 extra
    # queries to render one thread. Same counting approach as the events index
    # N+1 guard in spec/requests/events_spec.rb.
    it "does not issue a query per message to name senders" do
      create_list(:message, 15, conversation: conversation, sender: participant)
      create_list(:message, 15, :from_staff, conversation: conversation)

      query_count = 0
      counter = ->(*, payload) { query_count += 1 unless payload[:sql].match?(/\A(BEGIN|COMMIT|SAVEPOINT|RELEASE)/) }

      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
        get "/api/v1/admin/conversations/#{conversation.id}", headers: auth_headers(admin)
      end

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["messages"].size).to eq(30)
      # Auth, the conversation, its messages, the senders, their profiles, and
      # the participant-context queries. Generous upper bound so this doesn't
      # go flaky on unrelated changes — it only has to fail if preloading is
      # removed, which would put this well past 60.
      expect(query_count).to be <= 25
    end
  end

  describe "POST /api/v1/admin/conversations/:id/messages" do
    it "replies and moves the thread to pending" do
      post "/api/v1/admin/conversations/#{conversation.id}/messages",
           params: { body: "Checking now" }, headers: auth_headers(admin), as: :json

      expect(response).to have_http_status(:created)
      expect(response.parsed_body["message"]["sender_role"]).to eq(Message::STAFF)
      expect(conversation.reload.status).to eq(Conversation::PENDING)
    end

    it "leaves the thread read for staff, so it drops out of the inbox" do
      create(:message, conversation: conversation, sender: participant)

      post "/api/v1/admin/conversations/#{conversation.id}/messages",
           params: { body: "Answered" }, headers: auth_headers(admin), as: :json

      expect(Conversation.awaiting_staff).not_to include(conversation)
    end

    # The message row is itself an attributed record of what the admin did.
    # Duplicating it into admin_actions would drown the moderation history.
    it "does not write an audit row" do
      expect {
        post "/api/v1/admin/conversations/#{conversation.id}/messages",
             params: { body: "Answered" }, headers: auth_headers(admin), as: :json
      }.not_to change(AdminAction, :count)
    end

    it "rejects a blank body" do
      post "/api/v1/admin/conversations/#{conversation.id}/messages",
           params: { body: "  " }, headers: auth_headers(admin), as: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe "assignment" do
    it "claims a thread and audits it" do
      expect {
        post "/api/v1/admin/conversations/#{conversation.id}/assign", headers: auth_headers(admin)
      }.to change(AdminAction, :count).by(1)

      expect(conversation.reload.assigned_admin).to eq(admin)
      expect(AdminAction.last.action).to eq("assign_conversation")
    end

    # A soft claim, not a lock — the value is visibility, and enforcing
    # exclusivity would strand threads on whoever went on holiday.
    it "lets another admin take over a claimed thread" do
      conversation.update!(assigned_admin: other_admin)

      post "/api/v1/admin/conversations/#{conversation.id}/assign", headers: auth_headers(admin)

      expect(conversation.reload.assigned_admin).to eq(admin)
    end

    it "releases a claim" do
      conversation.update!(assigned_admin: admin)

      post "/api/v1/admin/conversations/#{conversation.id}/unassign", headers: auth_headers(admin)

      expect(conversation.reload.assigned_admin).to be_nil
      expect(AdminAction.last.action).to eq("unassign_conversation")
    end

    # Claiming means "I'm working this", and a closed thread has no work left.
    it "refuses to claim a resolved thread, and writes no audit row" do
      conversation.update!(status: Conversation::RESOLVED)

      expect {
        post "/api/v1/admin/conversations/#{conversation.id}/assign", headers: auth_headers(admin)
      }.not_to change(AdminAction, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["code"]).to eq("conversation_resolved")
      expect(conversation.reload.assigned_admin).to be_nil
    end

    # The asymmetry is deliberate: letting go of dead work is legitimate
    # cleanup, even though taking it on isn't.
    it "still releases a claim on a thread resolved while assigned" do
      conversation.update!(assigned_admin: admin, status: Conversation::RESOLVED)

      post "/api/v1/admin/conversations/#{conversation.id}/unassign", headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(conversation.reload.assigned_admin).to be_nil
    end
  end

  describe "POST /api/v1/admin/conversations/:id/resolve" do
    it "resolves, audits, and leaves a system note" do
      expect {
        post "/api/v1/admin/conversations/#{conversation.id}/resolve", headers: auth_headers(admin)
      }.to change(AdminAction, :count).by(1)

      expect(conversation.reload.status).to eq(Conversation::RESOLVED)
      expect(conversation.messages.last.sender_role).to eq(Message::SYSTEM)
      expect(AdminAction.last.action).to eq("resolve_conversation")
    end

    # Resolving frees the participant's one live slot.
    it "lets the participant start a fresh thread afterwards" do
      post "/api/v1/admin/conversations/#{conversation.id}/resolve", headers: auth_headers(admin)

      expect(build(:conversation, user: participant)).to be_valid
    end

    it "is idempotent and does not stack notices or audit rows" do
      post "/api/v1/admin/conversations/#{conversation.id}/resolve", headers: auth_headers(admin)

      expect {
        post "/api/v1/admin/conversations/#{conversation.id}/resolve", headers: auth_headers(admin)
      }.not_to change { [ AdminAction.count, Message.count ] }
    end
  end

  describe "POST /api/v1/admin/conversations/:id/read" do
    it "clears the thread from the awaiting inbox" do
      create(:message, conversation: conversation, sender: participant)

      post "/api/v1/admin/conversations/#{conversation.id}/read", headers: auth_headers(admin)

      expect(Conversation.awaiting_staff).not_to include(conversation)
    end

    # Reading isn't a moderation action, and an agent scrolling an inbox would
    # otherwise out-produce every other audit source combined.
    it "is not audited" do
      expect {
        post "/api/v1/admin/conversations/#{conversation.id}/read", headers: auth_headers(admin)
      }.not_to change(AdminAction, :count)
    end

    it "does not mark it read for the participant" do
      create(:message, :from_staff, conversation: conversation)

      post "/api/v1/admin/conversations/#{conversation.id}/read", headers: auth_headers(admin)

      expect(conversation.reload).to be_unread_for_participant
    end
  end
end
