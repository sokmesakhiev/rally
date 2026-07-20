module Api
  module V1
    class SurveyResponsesController < ApplicationController
      before_action :authenticate_user!

      # GET /api/v1/events/:event_id/survey_responses
      # Organizer sees all answers, grouped by registration
      def index
        event = current_user.events.find(params[:event_id])
        survey = event.survey

        unless survey
          render json: { responses: [] }
          return
        end

        registrations = event.registrations
          .includes(:user, user: :profile, registration_answers: :survey_question)
          .order(created_at: :asc)

        render json: {
          survey:    survey_summary(survey),
          responses: registrations.map { |r| response_json(r) }
        }
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Event not found" }, status: :not_found
      end

      private

      def survey_summary(survey)
        {
          id:        survey.id,
          title:     survey.title,
          questions: survey.survey_questions.order(position: :asc).map do |q|
            {
              id:            q.id,
              question_text: q.question_text,
              question_type: q.question_type,
              options:       q.options,
              required:      q.required
            }
          end
        }
      end

      def response_json(registration)
        {
          registration_id: registration.id,
          user: {
            id:           registration.user_id,
            display_name: registration.user.profile&.display_name,
            email:        registration.user.email
          },
          answers: registration.registration_answers.map do |a|
            {
              survey_question_id: a.survey_question_id,
              question_text:      a.survey_question&.question_text,
              question_type:      a.survey_question&.question_type,
              answer_text:        a.answer_text,
              answer_options:     a.answer_options
            }
          end
        }
      end
    end
  end
end
