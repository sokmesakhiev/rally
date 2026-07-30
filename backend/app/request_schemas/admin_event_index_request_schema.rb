# frozen_string_literal: true

# Validates the query string on GET /api/v1/admin/events.
#
# `status` exists here but not on the public EventIndexRequestSchema, because
# the public endpoint is hard-scoped to published events and must never offer
# a way to list drafts.
class AdminEventIndexRequestSchema < ApplicationRequestSchema
  MAX_PER_PAGE = 100
  DEFAULT_PER_PAGE = 25
  STATUSES = %w[all published draft].freeze

  params do
    optional(:q).maybe(:string)
    optional(:status).filled(:string, included_in?: STATUSES)
    optional(:category).filled(:string, included_in?: Event::CATEGORIES)
    optional(:page).filled(:integer, gt?: 0)
    optional(:per_page).filled(:integer, gt?: 0, lteq?: MAX_PER_PAGE)
  end
end
