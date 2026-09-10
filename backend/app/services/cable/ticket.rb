# frozen_string_literal: true

module Cable
  # Short-lived, single-use credentials for opening a WebSocket.
  #
  # ## Why this exists at all
  #
  # Everything else in this API authenticates with `Authorization: Bearer
  # <jwt>` (see ApplicationController#authenticate_user!). The browser
  # WebSocket API cannot set request headers, so that mechanism simply isn't
  # available at `wss://…/cable`.
  #
  # The usual workaround — putting the JWT in the query string — would write a
  # credential that stays valid for **30 days** (JsonWebToken::EXPIRY) into ALB
  # access logs, CloudWatch, and the user's own browser history. That is a real
  # disclosure, not a theoretical one, and it's the kind that survives long
  # enough to be exploited.
  #
  # So a client trades its JWT for one of these over ordinary authenticated
  # HTTP, and only the ticket travels in the URL. A leaked ticket is worthless
  # after TTL seconds, and worthless immediately once used.
  #
  # The alternative — smuggling the token through `Sec-WebSocket-Protocol`,
  # which browsers *do* let you set — works and saves a round trip, but abuses
  # a header meant for subprotocol negotiation. Rejected as harder to reason
  # about later.
  #
  # ## On the store
  #
  # `Rails.cache` is deliberate. In production it's Solid Cache, which is
  # Postgres-backed and therefore **shared across ECS tasks** — essential,
  # because the task that issues a ticket over HTTP is very often not the task
  # that terminates the subsequent WebSocket. An in-process store would work
  # perfectly in development and fail roughly half the time in production.
  #
  # Two consequences of that choice, neither obvious:
  #
  #   * **Test uses `:null_store`**, where writes vanish and reads return nil —
  #     so specs covering this must swap in a real store or they pass without
  #     testing anything. Hence the `:with_cache` tag (spec/support/cache_helpers.rb).
  #   * **A cache may evict.** Solid Cache trims under size pressure, so a
  #     ticket can in principle disappear before it's redeemed. Over a 30-second
  #     window that's remote, and the failure mode is a rejected connection that
  #     the client retries with a fresh ticket. Accepted rather than moving to a
  #     dedicated table.
  #
  # The obvious alternative is a signed, self-contained token
  # (`message_verifier.generate(..., expires_in: 30.seconds)`), which needs no
  # storage and sidesteps both points above. It was not chosen because it
  # cannot be single-use: a signed ticket stays replayable for its whole
  # lifetime, and single-use is the property that makes a ticket recovered from
  # a log worthless rather than merely short-lived.
  module Ticket
    # Long enough to survive a slow handshake on a bad connection, short enough
    # that a ticket captured from a log is dead before anyone reads the log.
    TTL = 30.seconds

    # 32 bytes from SecureRandom, same generator the rest of the app relies on
    # for token material.
    TOKEN_BYTES = 32

    class << self
      # Returns the raw ticket to hand to the client. Only its digest is
      # stored, so a dump of the cache table doesn't yield usable tickets —
      # same reasoning as storing password digests rather than passwords.
      def issue(user)
        raw = SecureRandom.urlsafe_base64(TOKEN_BYTES)
        Rails.cache.write(cache_key(raw), user.id, expires_in: TTL)
        raw
      end

      # Returns the User, or nil for anything wrong: unknown, expired, already
      # used, or belonging to an account that has since been deleted.
      #
      # Single use is enforced by deleting on read. There is a narrow race —
      # two simultaneous redemptions of the same ticket could both read before
      # either deletes — but both would have to originate from whoever already
      # holds the ticket, within the same instant, so it grants nothing an
      # attacker didn't already have. Worth knowing about; not worth a
      # distributed lock.
      def redeem(raw)
        return nil if raw.blank?

        key = cache_key(raw)
        user_id = Rails.cache.read(key)
        return nil if user_id.blank?

        Rails.cache.delete(key)
        User.find_by(id: user_id)
      end

      private

      def cache_key(raw)
        "cable:ticket:#{Digest::SHA256.hexdigest(raw)}"
      end
    end
  end
end
