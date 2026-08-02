# frozen_string_literal: true

# Validates the query string on GET /api/v1/admin/reports.
#
# `period` controls the bucket size for the events-created and
# platform-revenue time series — the dashboard shows one chart with a toggle
# between these three, rather than three separate always-visible charts.
class AdminReportsIndexRequestSchema < ApplicationRequestSchema
  PERIODS = %w[week month year].freeze

  params do
    optional(:period).filled(:string, included_in?: PERIODS)
  end
end
