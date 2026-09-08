# frozen_string_literal: true

module Api
  module V1
    # Trades an ordinary Bearer JWT for a short-lived ticket the browser can put
    # in a WebSocket URL. See Cable::Ticket for why the JWT itself must not go
    # there.
    class CableTicketsController < BaseController
      before_action :authenticate_user!

      # POST /api/v1/cable/ticket
      #
      # Called once per connection attempt — including every reconnect, and
      # ActionCable reconnects on its own after each deploy, since
      # `ecs update-service --force-new-deployment` severs every open socket.
      # Tickets are single-use, so a client cannot cache one and must come back
      # here each time.
      def create
        render json: {
          ticket: Cable::Ticket.issue(current_user),
          expires_in: Cable::Ticket::TTL.to_i
        }, status: :created
      end
    end
  end
end
