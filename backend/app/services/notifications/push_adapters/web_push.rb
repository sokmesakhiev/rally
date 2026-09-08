# frozen_string_literal: true

module Notifications
  module PushAdapters
    # Real delivery, via the `web-push` gem.
    #
    # The adapter boundary exists so a native app (FCM/APNs) can be added later
    # as a sibling of this class rather than by rewriting every call site. That
    # was the explicit scoping decision on this ticket: web push only for now,
    # but don't paint the sending path into a corner.
    class WebPush
      Result = Struct.new(:delivered, :expired, keyword_init: true)

      # Each subscription is sent independently and failures are contained.
      # One dead endpoint among fifty must not stop the other forty-nine —
      # which is exactly what a single raise partway through a loop would do.
      def deliver(subscriptions, payload)
        delivered = 0
        expired = 0

        subscriptions.each do |subscription|
          case send_one(subscription, payload)
          when :delivered then delivered += 1
          when :expired   then expired += 1
          end
        end

        Result.new(delivered: delivered, expired: expired)
      end

      private

      def send_one(subscription, payload)
        ::WebPush.payload_send(
          message: payload.to_json,
          vapid: {
            subject: Vapid.subject,
            public_key: Vapid.public_key,
            private_key: Vapid.private_key
          },
          **subscription.to_push_params
        )
        subscription.update_column(:last_delivered_at, Time.current)
        :delivered

      # 404/410 mean the browser has thrown this subscription away — a
      # reinstall, cleared site data, an uninstalled PWA. It is never coming
      # back, so retrying is pointless and keeping it live means every future
      # send wastes a request on it.
      rescue ::WebPush::ExpiredSubscription, ::WebPush::InvalidSubscription
        subscription.expire!
        :expired

      # Gateway and transport failures only — the push service being down, a
      # rate limit, a TLS or DNS blip. These are genuinely best-effort: there
      # is no useful recovery from "Chrome's push endpoint returned a 500", and
      # one unreachable device must not stop the others in the loop.
      #
      # Deliberately NOT `rescue StandardError`. That would also swallow the
      # ActiveRecord failures from #expire! and #update_column above, plus
      # ordinary programming errors, and degrade every one of them to a warn
      # log nobody reads. Anything not listed here propagates — and because
      # this always runs inside SendPushNotificationJob, propagating costs a
      # failed job with a backtrace rather than a broken request. The network
      # error list mirrors AbaPayway::Client#post_json's.
      rescue ::WebPush::Error, Timeout::Error, Errno::ECONNREFUSED, Errno::ECONNRESET,
             SocketError, OpenSSL::SSL::SSLError => e
        Rails.logger.warn(
          "[push] delivery failed subscription=#{subscription.id} " \
          "#{e.class}: #{e.message}"
        )
        :failed
      end
    end
  end
end
