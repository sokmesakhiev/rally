# Delivers a push notification out of band.
#
# Sending is one HTTPS request per subscribed device, to a third party we don't
# control. Doing that inline would put a browser vendor's latency — or
# outage — directly into the response time of registering for an event, which
# is exactly the trade the existing mailers already refuse by using
# deliver_later.
#
# Takes a user_id rather than a User so the job payload stays small and can't
# carry a stale record; GlobalID would serialize the whole object.
class SendPushNotificationJob < ApplicationJob
  queue_as :default

  # A deleted user (or one whose account was discarded between enqueue and
  # perform) is a normal outcome here, not an error worth retrying.
  discard_on ActiveJob::DeserializationError

  def perform(user_id, title:, body:, url: "/", tag: nil)
    user = User.find_by(id: user_id)
    return if user.nil?

    Notifications::DeliverPush.call(user: user, title: title, body: body, url: url, tag: tag)
  end
end
