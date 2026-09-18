# frozen_string_literal: true

# Validates POST /api/v1/events/:event_id/reports.
#
# `details` is optional and capped rather than required: making a reporter
# write an essay is friction on the one action Rally wants to be frictionless,
# and a bare category with no prose is still a usable signal — the reviewer
# opens the event page either way.
class EventReportRequestSchema < ApplicationRequestSchema
  params do
    required(:report).hash do
      required(:reason).filled(:string, included_in?: EventReport::REASONS)
      optional(:details).maybe(:string, max_size?: 2_000)
    end
  end
end
