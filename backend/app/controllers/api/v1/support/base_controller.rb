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

        def conversation_json(conversation)
          return nil if conversation.nil?

          {
            id: conversation.id,
            status: conversation.status,
            subject: conversation.subject,
            unread_count: conversation.unread_count_for_participant,
            last_message_at: conversation.last_message_at,
            created_at: conversation.created_at
          }
        end

        # Deliberately carries no sender name.
        #
        # A participant needs to know which side spoke, not which employee did.
        # Staff messages render from `sender_role` as "Rally Support", so an
        # admin's display name never reaches an arbitrary user, and a message
        # whose sender was deleted needs no special case. The staff-side
        # serializer (Ticket C) is a different one and does show the
        # participant, which is the direction that matters for context.
        def message_json(message)
          {
            id: message.id,
            body: message.body,
            sender_role: message.sender_role,
            created_at: message.created_at
          }
        end
      end
    end
  end
end
