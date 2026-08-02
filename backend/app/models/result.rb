# A participant's finish time for the event they registered for. Optional —
# most event types (a social gathering, a group ride with no timing) simply
# never get one; race-style events (a half marathon, a 10K) are where an
# organizer would set this, either one at a time or via CSV import (see
# Api::V1::ResultsController).
#
# finish_time_seconds is a plain integer count of seconds, not a "HH:MM:SS"
# string — sorting/leaderboard-style queries and CSV parsing both stay
# trivial this way; formatting to/from a duration string happens at the
# edges (the frontend, and Results::ImportCsv's row parsing), not here.
class Result < ApplicationRecord
  belongs_to :registration

  validates :registration_id, uniqueness: true
  validates :finish_time_seconds, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true

  # Accepts what an organizer would plausibly type or paste into a CSV:
  # "H:MM:SS", "MM:SS", or a bare integer (already seconds). Returns nil
  # for anything else — callers (Results::ImportCsv) treat nil as "invalid,
  # skip this row" rather than raising, so one bad cell doesn't abort an
  # otherwise-good import.
  def self.parse_duration_to_seconds(raw)
    value = raw.to_s.strip
    return nil if value.blank?

    case value
    when /\A\d+\z/
      value.to_i
    when /\A(\d{1,2}):(\d{2}):(\d{2})\z/
      $~[1].to_i * 3600 + $~[2].to_i * 60 + $~[3].to_i
    when /\A(\d{1,3}):(\d{2})\z/
      $~[1].to_i * 60 + $~[2].to_i
    end
  end
end
