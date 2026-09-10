# frozen_string_literal: true

module Api
  module V1
    module Support
      class ConversationsController < BaseController
        # GET /api/v1/support/conversation
        #
        # Returns null rather than 404 when there isn't one: "you have no
        # support thread" is a perfectly ordinary state for almost every user,
        # and the launcher polls this for its unread badge. A 404 would make
        # the normal case look like an error in every client log.
        def show
          render json: { conversation: conversation_json(live_conversation) }
        end

        # POST /api/v1/support/conversation
        #
        # Idempotent — the widget calls it whenever the panel opens, and a
        # double-tap must not produce two threads. 200 for one that already
        # existed, 201 for one this call actually made, so a client can tell
        # the difference without diffing timestamps.
        def create
          validate_params_with_schema(SupportConversationCreateRequestSchema) do |output|
            # Stripped, not raw. The schema measures the *stripped* length, so
            # 200 characters padded with trailing whitespace passes validation
            # and then fails the model's own 200-character limit — a 500 for
            # input the boundary just accepted. Matches what
            # MessagesController#create already does with the body.
            #
            # ::-qualified — see the note in MessagesController#create.
            result = ::Conversations::Start.call(
              user: current_user,
              subject: output[:subject].to_s.strip.presence
            )

            render json: { conversation: conversation_json(result.conversation) },
                   status: result.created ? :created : :ok
          end
        end

        # POST /api/v1/support/read
        #
        # Stamps participant_last_read_at, clearing the launcher badge. No
        # message id: there is one thread and reading it means reading all of
        # it, so a per-message receipt would be state nobody queries.
        def read
          conversation = live_conversation
          return render json: { conversation: nil } if conversation.nil?

          conversation.mark_read_for_participant!

          render json: { conversation: conversation_json(conversation) }
        end
      end
    end
  end
end
