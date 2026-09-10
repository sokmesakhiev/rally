# frozen_string_literal: true

module ApplicationCable
  # Authenticates a WebSocket once, at connect time, and identifies it for the
  # life of the socket.
  #
  # Unlike a controller, there is no per-action hook here — `connect` runs once
  # and the connection then persists for hours. Two consequences worth holding
  # on to:
  #
  #   1. **Authorization must still be checked per subscription**, in each
  #      channel's `subscribed`. This method only establishes *who* is on the
  #      other end.
  #   2. **Account state is checked here and then never again.** A user
  #      suspended mid-session keeps their socket until it drops. That's a
  #      real gap and it's accepted deliberately: the same 30-day stateless
  #      JWT problem exists on the HTTP side, where ApplicationController
  #      re-checks on every request. If suspension needs to sever live sockets,
  #      the fix is an explicit disconnect broadcast from User#suspend!, not a
  #      periodic re-check here.
  class Connection < ActionCable::Connection::Base
    identified_by :current_user

    def connect
      self.current_user = find_verified_user
    end

    private

    # `reject_unauthorized_connection` raises, closing the socket with a 401
    # before any channel code runs.
    def find_verified_user
      user = Cable::Ticket.redeem(request.params[:ticket])
      reject_unauthorized_connection if user.nil?

      # Mirrors ApplicationController#authenticate_user!'s two account-state
      # gates. A ticket is only issued to an account that passed them a moment
      # ago, so this is belt-and-braces rather than the primary guard — but
      # cheap, and the cost of getting it wrong is a suspended account holding
      # a live channel.
      reject_unauthorized_connection if user.suspended? || user.discarded?

      logger.add_tags("ActionCable", "user:#{user.id}")
      user
    end
  end
end
