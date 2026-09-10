# frozen_string_literal: true

module Api
  module V1
    module Support
      # Participant side of support chat. The staff side lives under
      # Api::V1::Admin (Ticket C) — deliberately a different namespace with a
      # different base class, so an endpoint can't accidentally be reachable by
      # the wrong audience just by being in the wrong file.
      #
      # Everything here is scoped to `current_user`'s own conversation. There
      # is no `:id` in any of these routes: a participant has at most one live
      # thread, so "which conversation" is never a parameter the caller gets to
      # choose, and there is correspondingly nothing to authorize per-record.
      class BaseController < Api::V1::BaseController
        before_action :authenticate_user!

        private

        def live_conversation
          @live_conversation ||= current_user.conversations.live.first
        end

        # Shapes live in Support::Serializers, not here, because the WebSocket
        # broadcast (Ticket D) sends the same payloads. A socket payload that
        # drifts from the REST one is nasty to debug: the client merges both
        # into one list, so the mismatch shows up as messages rendering
        # differently depending on whether they arrived live or after a refresh.
        def conversation_json(conversation)
          ::Support::Serializers.participant_conversation(conversation)
        end

        def message_json(message)
          ::Support::Serializers.participant_message(message)
        end
      end
    end
  end
end
