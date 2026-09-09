require "rails_helper"

RSpec.describe "Notifications API", type: :request do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }

  describe "GET /api/v1/notifications" do
    it "requires a session" do
      get "/api/v1/notifications"

      expect(response).to have_http_status(:unauthorized)
    end

    it "returns the caller's notifications, newest first, with an unread count" do
      # created_at is set on all three, including the read one: the :read trait
      # only sets read_at, so leaving created_at to default would make the
      # oldest-by-intent row the newest by ordering.
      create(:notification, user: user, title: "Older", created_at: 2.hours.ago)
      create(:notification, user: user, title: "Newer", created_at: 1.minute.ago)
      create(:notification, :read, user: user, title: "Already read", created_at: 3.hours.ago)

      get "/api/v1/notifications", headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["notifications"].map { |n| n["title"] })
        .to eq([ "Newer", "Older", "Already read" ])
      expect(body["unread_count"]).to eq(2)
      expect(body["max_count"]).to eq(Notification::MAX_BADGE_COUNT)
    end

    it "never returns another user's notifications" do
      create(:notification, user: other_user, title: "Not yours")

      get "/api/v1/notifications", headers: auth_headers(user)

      expect(response.parsed_body["notifications"]).to be_empty
      expect(response.parsed_body["unread_count"]).to eq(0)
    end

    # This endpoint is polled by every open tab, so the page size is a cap on
    # how much work a bored user with a lot of history can cause.
    it "caps how many it returns" do
      create_list(:notification, Api::V1::NotificationsController::PAGE_SIZE + 5, user: user)

      get "/api/v1/notifications", headers: auth_headers(user)

      expect(response.parsed_body["notifications"].size)
        .to eq(Api::V1::NotificationsController::PAGE_SIZE)
    end
  end

  describe "POST /api/v1/notifications/:id/read" do
    it "marks it read and returns the new count" do
      notification = create(:notification, user: user)
      create(:notification, user: user)

      post "/api/v1/notifications/#{notification.id}/read", headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["unread_count"]).to eq(1)
      expect(notification.reload).to be_read
    end

    # Scoped to the caller: knowing an id must not be enough to clear someone
    # else's badge.
    it "404s on another user's notification, and leaves it unread" do
      notification = create(:notification, user: other_user)

      post "/api/v1/notifications/#{notification.id}/read", headers: auth_headers(user)

      expect(response).to have_http_status(:not_found)
      expect(notification.reload).not_to be_read
    end
  end

  describe "POST /api/v1/notifications/read_all" do
    it "clears the caller's badge" do
      create_list(:notification, 3, user: user)

      post "/api/v1/notifications/read_all", headers: auth_headers(user)

      expect(response.parsed_body["unread_count"]).to eq(0)
      expect(user.notifications.unread).to be_empty
    end

    it "leaves other users' notifications alone" do
      mine = create(:notification, user: user)
      theirs = create(:notification, user: other_user)

      post "/api/v1/notifications/read_all", headers: auth_headers(user)

      expect(mine.reload).to be_read
      expect(theirs.reload).not_to be_read
    end
  end
end
