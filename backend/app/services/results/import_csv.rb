# frozen_string_literal: true

require "csv"

module Results
  # Bulk-sets finish times for one event's participants from an
  # organizer-provided CSV. Header row must carry `finish_time` plus at least
  # one identifying column — `bib` or `email`. `finish_time` accepts
  # "H:MM:SS", "MM:SS", or a bare integer number of seconds (see
  # Result.parse_duration_to_seconds).
  #
  # ── Why bib, and why it wins over email ─────────────────────────────────────
  # Email was the only match key until bib numbers existed
  # (docs/partner-api-design.md, D10). That was always the wrong key for the
  # file organizers actually have: chip-timing systems export bib and time,
  # and no timing exporter in the world emits entrant email addresses. An
  # organizer with a timing export had to VLOOKUP it against their entrant
  # list before Rally would accept it.
  #
  # When a row carries both, bib wins. It is the identifier physically
  # attached to the person who crossed the line, whereas the email in a
  # merged spreadsheet is whatever the merge produced. A row whose bib and
  # email point at *different* registrations is a genuine conflict and is
  # reported as one rather than silently resolved — a mismatched pair means
  # the file is wrong somewhere, and picking either side would write a
  # finish time onto the wrong runner.
  #
  # Deliberately processes every row rather than aborting on the first bad
  # one (unknown bib, unparseable time, etc.) — an organizer importing a
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
          errors << {
            row: row_number,
            # Echo whichever key the row actually used, so the error list is
            # readable against the file the organizer uploaded.
            bib: bib_of(row),
            email: email_of(row),
            reason: error
          }
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

    # `bib_number` accepted alongside `bib` because a file exported from
    # Rally's own participant CSV will use the longer header.
    def bib_of(row)
      (row[:bib] || row[:bib_number]).to_s.strip.presence
    end

    def email_of(row)
      row[:email].to_s.strip.downcase.presence
    end

    # Returns nil on success, or an error message string.
    def process_row(row)
      bib = bib_of(row)
      email = email_of(row)
      return "missing bib and email — the row identifies nobody" if bib.blank? && email.blank?

      registration, error = find_registration(bib, email)
      return error unless registration

      seconds = Result.parse_duration_to_seconds(row[:finish_time])
      return "invalid finish_time (use H:MM:SS, MM:SS, or a number of seconds)" if seconds.nil?

      result = Result.find_or_initialize_by(registration: registration)
      return result.errors.full_messages.join(", ") unless result.update(finish_time_seconds: seconds)

      nil
    end

    # Returns [registration, nil] or [nil, error_message].
    def find_registration(bib, email)
      by_bib   = bib.present? ? @event.registrations.kept.find_by(bib_number: bib) : nil
      by_email = email.present? ? @event.registrations.kept.joins(:user).find_by(users: { email: email }) : nil

      return [ nil, "no registration found for bib #{bib} on this event" ] if bib.present? && by_bib.nil?
      return [ nil, "no registration found for this email on this event" ] if email.present? && by_email.nil?

      if by_bib && by_email && by_bib.id != by_email.id
        return [ nil, "bib #{bib} and this email belong to different participants" ]
      end

      [ by_bib || by_email, nil ]
    end
  end
end
