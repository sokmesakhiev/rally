# frozen_string_literal: true

module Notifications
  module PushAdapters
    # What runs when no VAPID keypair is configured — development, test, CI,
    # and any production deploy where push hasn't been set up yet.
    #
    # Logs instead of sending, and reports success. Deliberately not an error:
    # a missing notification channel must never fail the thing that triggered
    # it. Someone registering for an event should not see their registration
    # break because push isn't configured.
    #
    # Mirrors the same "unset means cleanly off" convention the rest of the app
    # already uses for Google sign-in, reCAPTCHA and Sentry.
    class Null
      Result = Struct.new(:delivered, :expired, keyword_init: true)

      def deliver(subscriptions, payload)
        subscriptions.each do |subscription|
          Rails.logger.info(
            "[push:null] would notify user=#{subscription.user_id} " \
            "endpoint=#{subscription.endpoint.truncate(60)} " \
            "title=#{payload[:title].inspect}"
          )
        end

        Result.new(delivered: subscriptions.size, expired: 0)
      end
    end
  end
end
