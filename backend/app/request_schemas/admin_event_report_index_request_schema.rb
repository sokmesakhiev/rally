# frozen_string_literal: true

# Validates GET /api/v1/admin/event_reports. Same `page`/`per_page` convention
# as the other paginated admin lists.
class AdminEventReportIndexRequestSchema < ApplicationRequestSchema
  MAX_PER_PAGE = 100
  DEFAULT_PER_PAGE = 25

  # `open` is the default view rather than "all": the queue is a worklist, and
  # a reviewer opening it wants what still needs doing. History is a filter
  # away, not the landing state.
  STATUSES = EventReport::STATUSES
  REASONS = EventReport::REASONS

  params do
    optional(:status).filled(:string, included_in?: STATUSES)
    optional(:reason).filled(:string, included_in?: REASONS)
    optional(:page).filled(:integer, gt?: 0)
    optional(:per_page).filled(:integer, gt?: 0, lteq?: MAX_PER_PAGE)
  end
end
