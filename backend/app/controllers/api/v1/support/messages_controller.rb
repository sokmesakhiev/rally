# frozen_string_literal: true

module Api
  module V1
    module Support
      class MessagesController < BaseController
        # One screenful of history, and the ceiling on a catch-up page. The
        # thread view is short-lived and rarely scrolled; the reason for a cap
        # at all is that this endpoint is what a reconnecting client hits, and
        # a client that has been away for a week must not pull its entire
        # history into one response.
        PAGE_SIZE = 50

        # GET /api/v1/support/messages[?after=<id>|?before=<id>]
        #
        # Three modes, and `has_more` answers the question belonging to each:
        #
        #   (none)    newest page, oldest-first. has_more => older history
        #             exists above it; fetch with ?before=<first id>.
        #   ?after=   the reconnect catch-up — everything since the client's
        #             last known message. has_more => more still waiting, ask
        #             again. This is why Ticket D's WebSocket can be treated as
        #             an optimisation rather than a guarantee: every deploy
        #             severs every connection, so a client reconnects and asks
        #             what it missed instead of trusting nothing was dropped.
        #   ?before=  scrolling back. has_more => yet older history exists.
        #
        # `before` exists because without it `has_more` on a first page is a
        # flag a client can see but not act on, and a thread longer than one
        # page would have a beginning the participant could never reach.
        # Ignored if `after` is also given: catching up on what you missed is
        # never the same request as scrolling into history.
        def index
          conversation = live_conversation
          return render json: { conversation: nil, messages: [], has_more: false } if conversation.nil?

          messages, has_more = page_for(conversation)

          render json: {
            conversation: conversation_json(conversation),
            messages: messages.map { |m| message_json(m) },
            has_more: has_more
          }
        end

        # POST /api/v1/support/messages
        #
        # Starts a thread if there isn't a live one, rather than requiring the
        # client to call POST /support/conversation first. Sending a message is
        # the participant's actual intent, and failing it because of a missing
        # setup call would be an avoidable error in the one flow that matters.
        # Conversations::Start is race-safe, so this stays idempotent even if
        # two messages are sent at once from a cold start.
        def create
          validate_params_with_schema(SupportMessageCreateRequestSchema) do |output|
            # ::-qualified: this controller sits inside `module Support`, so an
            # unqualified `Conversations::…` would resolve against that lexical
            # scope first. Explicit here rather than relying on the fallthrough.
            conversation = live_conversation || ::Conversations::Start.call(user: current_user).conversation

            message = ::Conversations::PostMessage.call(
              conversation: conversation,
              sender: current_user,
              body: output[:body].strip
            )

            render json: {
              message: message_json(message),
              conversation: conversation_json(conversation.reload)
            }, status: :created
          end
        end

        private

        # Fetches one extra row rather than issuing a separate COUNT: the only
        # question is "is there at least one more", and a count of a thread
        # somebody has been using for months costs more than the answer is
        # worth.
        def page_for(conversation)
          after = params[:after].presence
          return forward_page(conversation, after) if after

          # Both remaining modes want the *newest* rows of their range, so both
          # walk descending and flip. reorder, not order: the has_many carries a
          # default ascending order and `order` would append rather than replace
          # it, leaving "ORDER BY created_at ASC, created_at DESC" and silently
          # returning the oldest page instead of the newest.
          scope = conversation.messages
          before = params[:before].presence
          scope = scope.before_id(before) if before

          page = scope.reorder(created_at: :desc, id: :desc).limit(PAGE_SIZE + 1).to_a
          [ page.first(PAGE_SIZE).reverse, page.size > PAGE_SIZE ]
        end

        def forward_page(conversation, cursor)
          page = conversation.messages.after_id(cursor).oldest_first.limit(PAGE_SIZE + 1).to_a
          [ page.first(PAGE_SIZE), page.size > PAGE_SIZE ]
        end
      end
    end
  end
end
