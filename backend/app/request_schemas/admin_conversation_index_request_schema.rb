# frozen_string_literal: true

# Validates the query string on GET /api/v1/admin/conversations.
class AdminConversationIndexRequestSchema < ApplicationRequestSchema
  MAX_PER_PAGE = 100
  DEFAULT_PER_PAGE = 25

  # "live" (open + pending) is its own filter rather than making agents tick
  # two boxes — it's the default view of an inbox, and the distinction between
  # "we owe them" and "they owe us" is a sort concern, not a visibility one.
  STATUSES = %w[all live open pending resolved].freeze

  # mine / unassigned / any. Assigning *to another admin* is deliberately not
  # supported yet — see the ConversationsController note.
  ASSIGNMENTS = %w[any mine unassigned].freeze

  params do
    optional(:status).filled(:string, included_in?: STATUSES)
    optional(:assignment).filled(:string, included_in?: ASSIGNMENTS)
    optional(:unread).filled(:bool)
    optional(:page).filled(:integer, gt?: 0)
    optional(:per_page).filled(:integer, gt?: 0, lteq?: MAX_PER_PAGE)
  end
end
