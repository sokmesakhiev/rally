# frozen_string_literal: true

# Validates PATCH /api/v1/registrations/:id/result (organizer manually
# setting/clearing one participant's finish time). CSV import
# (Results::ImportCsv) parses its own "H:MM:SS"/"MM:SS" strings into
# seconds before ever touching the Result model — this schema only covers
# the manual, one-at-a-time path, where the frontend already converts a
# duration input into seconds before sending it.
class ResultUpdateRequestSchema < ApplicationRequestSchema
  params do
    required(:result).hash do
      # maybe(:integer), not optional — sending finish_time_seconds: null
      # is how the frontend clears a mistaken entry.
      optional(:finish_time_seconds).maybe(:integer)
    end
  end
end
