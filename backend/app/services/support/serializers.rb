# frozen_string_literal: true

module Support
  # The wire shapes for support chat, in one place.
  #
  # These started as private methods on the two controllers. They moved here
  # when Ticket D added a third caller — the WebSocket broadcast — because a
  # socket payload that drifts from the REST payload is a particularly nasty
  # bug: the client merges both into one list, so a mismatch shows up as
  # messages that render differently depending on whether they arrived live or
  # after a refresh.
  #
  # Two audiences, deliberately different:
  #
  #   * `participant_*` omits any sender name. A participant needs to know
  #     which *side* spoke, not which employee, so staff messages render from
  #     `sender_role` alone and an admin's name never reaches an arbitrary user.
  #   * `staff_*` names the colleague who replied and identifies the
  #     participant. Everyone reading it is already staff.
  module Serializers
    module_function

    def participant_message(message)
      {
        id: message.id,
        body: message.body,
        sender_role: message.sender_role,
        created_at: message.created_at
      }
    end

    def participant_conversation(conversation)
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

    def staff_message(message)
      {
        id: message.id,
        body: message.body,
        sender_role: message.sender_role,
        sender_id: message.sender_id,
        sender_name: staff_sender_name(message),
        created_at: message.created_at
      }
    end

    # `unread` is passed in when a caller computed it for a whole page at once
    # (Conversation.unread_ids_among), and falls back to the per-row query for
    # a single conversation.
    def staff_conversation(conversation, unread: nil)
      {
        id: conversation.id,
        status: conversation.status,
        subject: conversation.subject,
        unread: unread.nil? ? conversation.unread_for_staff? : unread,
        assigned_admin_id: conversation.assigned_admin_id,
        last_message_at: conversation.last_message_at,
        created_at: conversation.created_at,
        participant: {
          id: conversation.user_id,
          display_name: conversation.user.profile&.display_name,
          email: conversation.user.email
        }
      }
    end

    def staff_conversation_detail(conversation, unread: nil)
      staff_conversation(conversation, unread: unread).merge(
        staff_last_read_at: conversation.staff_last_read_at,
        participant_last_read_at: conversation.participant_last_read_at
      )
    end

    def staff_sender_name(message)
      return nil if message.system?
      return "Deleted account" if message.orphaned_sender?

      message.sender.profile&.display_name || message.sender.email
    end
  end
end
