module Api
  module V1
    # In-app notifications — what the header bell counts and lists.
    class NotificationsController < BaseController
      before_action :authenticate_user!

      # How many the dropdown shows. Everything older is still in the table;
      # there just isn't a UI for it yet, and paginating a list nobody scrolls
      # would be premature.
      PAGE_SIZE = 20

      # GET /api/v1/notifications
      #
      # Polled roughly once a minute by every open tab, so it stays a single
      # indexed query and returns no associations. `unread_count` is capped at
      # Notification::MAX_BADGE_COUNT — a badge reading "99+" is as actionable
      # as one reading "247", and the cap keeps the count cheap.
      def index
        notifications = current_user.notifications.newest_first.limit(PAGE_SIZE)

        render json: {
          notifications: notifications.map { |n| notification_json(n) },
          unread_count: Notification.badge_count_for(current_user),
          max_count: Notification::MAX_BADGE_COUNT
        }
      end

      # POST /api/v1/notifications/:id/read
      def read
        notification = current_user.notifications.find(params[:id])
        notification.mark_read!

        render json: {
          notification: notification_json(notification),
          unread_count: Notification.badge_count_for(current_user)
        }
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Notification not found" }, status: :not_found
      end

      # POST /api/v1/notifications/read_all
      #
      # update_all, not each(&:mark_read!): this is the "clear the badge"
      # button, there are no callbacks to run, and one statement beats N.
      def read_all
        current_user.notifications.unread.update_all(read_at: Time.current, updated_at: Time.current)

        render json: { unread_count: 0 }
      end

      private

      def notification_json(notification)
        {
          id: notification.id,
          kind: notification.kind,
          title: notification.title,
          body: notification.body,
          url: notification.url,
          event_id: notification.event_id,
          read: notification.read?,
          created_at: notification.created_at
        }
      end
    end
  end
end
