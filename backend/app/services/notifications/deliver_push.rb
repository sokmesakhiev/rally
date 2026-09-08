# frozen_string_literal: true

module Notifications
  # Sends one notification to every live subscription a user has.
  #
  # The single entry point for push. Call sites name a user and a payload and
  # know nothing about VAPID, adapters, or which of the user's four browsers
  # are still reachable.
  #
  #   Notifications::DeliverPush.call(
  #     user: registration.user,
  #     title: "You're registered",
  #     body: "See you at #{event.title}",
  #     url: "/dashboard"
  #   )
  #
  # Push runs *alongside* the existing mailers, never instead of them. Email is
  # the channel everyone has; push is an extra for people who opted in on a
  # device. Nothing here should ever be the only way a participant learns
  # something.
  class DeliverPush
    def self.call(...)
      new(...).call
    end

    def initialize(user:, title:, body:, url: "/", tag: nil)
      @user = user
      @title = title
      @body = body
      @url = url
      @tag = tag
    end

    def call
      return no_subscriptions if subscriptions.empty?

      adapter.deliver(subscriptions, payload)
    end

    # Picked per call rather than memoized at boot so that configuring VAPID
    # keys takes effect without a restart, and so specs can toggle it per
    # example — the same reasoning as AbaPayway::Client.config.
    def self.adapter
      Vapid.configured? ? PushAdapters::WebPush.new : PushAdapters::Null.new
    end

    private

    def adapter
      self.class.adapter
    end

    def subscriptions
      @subscriptions ||= @user ? @user.push_subscriptions.active.to_a : []
    end

    def payload
      {
        title: @title,
        body: @body,
        url: @url,
        # Lets the service worker collapse repeats: a second notification with
        # the same tag replaces the first rather than stacking. Without it, a
        # participant who registers for three events gets three separate
        # "You're registered" banners.
        tag: @tag
      }.compact
    end

    def no_subscriptions
      PushAdapters::Null::Result.new(delivered: 0, expired: 0)
    end
  end
end
