# frozen_string_literal: true

# Validates the query string on GET /api/v1/admin/users.
class AdminUserIndexRequestSchema < ApplicationRequestSchema
  MAX_PER_PAGE = 100
  DEFAULT_PER_PAGE = 25
  STATUSES = %w[all active suspended].freeze

  params do
    optional(:q).maybe(:string)
    optional(:status).filled(:string, included_in?: STATUSES)
    optional(:page).filled(:integer, gt?: 0)
    optional(:per_page).filled(:integer, gt?: 0, lteq?: MAX_PER_PAGE)
  end
end
