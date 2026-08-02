# frozen_string_literal: true

require "csv"

module Results
  # Bulk-sets finish times for one event's participants from an
  # organizer-provided CSV. Expected header row: `email,finish_time` —
  # `finish_time` accepts "H:MM:SS", "MM:SS", or a bare integer number of
  # seconds (see Result.parse_duration_to_seconds).
  #
  # Deliberately processes every row rather than aborting on the first bad
  # one (unknown email, unparseable time, etc.) — an organizer importing a
  # few hundred rows shouldn't have to fix one typo and re-upload from
  # scratch. Returns a summary the controller renders as-is so the frontend
  # can show exactly which rows didn't take and why.
  class ImportCsv
    def self.call(event:, csv_text:)
      new(event, csv_text).call
    end

    def initialize(event, csv_text)
      @event = event
      @csv_text = csv_text
    end

    def call
      updated = 0
      errors = []

      rows.each.with_index(2) do |row, row_number|
        error = process_row(row)
        if error
          errors << { row: row_number, email: row[:email].to_s.strip, reason: error }
        else
          updated += 1
        end
      end

      { updated: updated, errors: errors }
    end

    private

    def rows
      CSV.parse(@csv_text, headers: true, header_converters: ->(h) { h.to_s.strip.downcase.to_sym })
    end

    # Returns nil on success, or an error message string.
    def process_row(row)
      email = row[:email].to_s.strip.downcase
      return "missing email" if email.blank?

      registration = @event.registrations.joins(:user).find_by(users: { email: email })
      return "no registration found for this email on this event" unless registration

      seconds = Result.parse_duration_to_seconds(row[:finish_time])
      return "invalid finish_time (use H:MM:SS, MM:SS, or a number of seconds)" if seconds.nil?

      result = Result.find_or_initialize_by(registration: registration)
      return result.errors.full_messages.join(", ") unless result.update(finish_time_seconds: seconds)

      nil
    end
  end
end
