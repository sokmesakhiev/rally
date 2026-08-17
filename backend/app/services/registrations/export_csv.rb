# frozen_string_literal: true

require "csv"

module Registrations
  # Builds a CSV of one event's registration list for offline use (check-in
  # sheets, mail merges) — see Api::V1::RegistrationsController#export.
  #
  # Column set is fixed for the base fields, plus one dynamic column per
  # survey question when the event has a survey attached, mirroring what
  # organizers already see under the "Responses" tab
  # (Api::V1::SurveyResponsesController). Excludes discarded (organizer-
  # removed) registrations, same as #event_registrations — see
  # Registration#discard!.
  class ExportCsv
    def self.call(event:)
      new(event).call
    end

    def initialize(event)
      @event = event
      @questions = event.survey&.survey_questions&.order(:position)&.to_a || []
    end

    def call
      CSV.generate do |csv|
        csv << headers
        registrations.each { |registration| csv << row(registration) }
      end
    end

    private

    attr_reader :event, :questions

    def registrations
      event.registrations.kept
        .includes({ user: :profile }, :event_types, :registration_answers)
        .order(created_at: :asc)
    end

    def headers
      [
        "Name", "Email", "Event Type(s)", "Status", "Payment Status",
        "Amount Paid (#{event.currency.upcase})", "Checked In", "Checked In At",
        "Registered At"
      ] + questions.map(&:question_text)
    end

    def row(registration)
      [
        registration.user.profile&.display_name.presence || "—",
        registration.user.email,
        registration.event_types.map(&:name).join(", "),
        registration.status,
        registration.payment_status,
        format("%.2f", registration.amount_paid_cents / 100.0),
        registration.checked_in_at.present? ? "Yes" : "No",
        registration.checked_in_at&.iso8601,
        registration.created_at.iso8601
      ] + questions.map { |q| answer_for(registration, q) }
    end

    # Reads from the preloaded registration_answers array (no query per
    # row/question) rather than `registration.registration_answers.find_by`.
    def answer_for(registration, question)
      answer = registration.registration_answers.find { |a| a.survey_question_id == question.id }
      return nil unless answer

      if question.question_type == "text"
        answer.answer_text
      else
        question.options
          .select { |o| answer.answer_options.include?(o["id"]) }
          .map { |o| o["label"] }
          .join("; ")
      end
    end
  end
end
