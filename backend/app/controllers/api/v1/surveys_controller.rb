module Api
  module V1
    class SurveysController < BaseController
      before_action :authenticate_user!
      before_action :set_survey, only: [ :show, :update, :destroy ]
      before_action :authorize_owner!, only: [ :update, :destroy ]

      # GET /api/v1/surveys — current user's surveys
      def index
        surveys = current_user.surveys.kept.includes(:survey_questions).order(created_at: :desc)
        render json: { surveys: surveys.map { |s| survey_json(s) } }
      end

      # GET /api/v1/surveys/:id
      def show
        render json: { survey: survey_json(@survey, include_questions: true) }
      end

      # POST /api/v1/surveys
      def create
        validate_params_with_schema(SurveyRequestSchema) do |validated_params|
          survey = current_user.surveys.build(survey_params_base(validated_params))

          (validated_params[:questions] || []).each_with_index do |q, i|
            survey.survey_questions.build(question_params(q).merge(position: i))
          end

          if survey.save
            render json: { survey: survey_json(survey, include_questions: true) }, status: :created
          else
            render json: { error: survey.errors.full_messages.join(", ") }, status: :unprocessable_entity
          end
        end
      end

      # PATCH /api/v1/surveys/:id — replace questions entirely
      def update
        validate_params_with_schema(SurveyRequestSchema) do |validated_params|
          Survey.transaction do
            @survey.update!(survey_params_base(validated_params))

            if validated_params.key?(:questions)
              @survey.survey_questions.destroy_all
              (validated_params[:questions] || []).each_with_index do |q, i|
                @survey.survey_questions.create!(question_params(q).merge(position: i))
              end
            end
          end

          render json: { survey: survey_json(@survey.reload, include_questions: true) }
        end
      rescue ActiveRecord::RecordInvalid => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # DELETE /api/v1/surveys/:id — soft-delete (see Survey#discard!)
      def destroy
        @survey.discard!
        render json: { message: "Survey deleted" }
      end

      private

      def set_survey
        @survey = Survey.kept.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Survey not found" }, status: :not_found
      end

      def authorize_owner!
        unless @survey.creator_id == current_user.id
          render json: { error: "Forbidden" }, status: :forbidden
        end
      end

      def survey_params_base(validated_params)
        { title: validated_params[:title].presence || "Registration Survey" }
      end

      def question_params(q)
        {
          question_text: q[:question_text],
          question_type: q[:question_type] || "text",
          options:       q[:options] || [],
          required:      q[:required] || false
        }
      end

      def survey_json(survey, include_questions: false)
        json = {
          id:         survey.id,
          creator_id: survey.creator_id,
          title:      survey.title,
          created_at: survey.created_at,
          updated_at: survey.updated_at
        }
        if include_questions
          json[:questions] = survey.survey_questions.map { |q| question_json(q) }
        else
          json[:questions_count] = survey.survey_questions.size
        end
        json
      end

      def question_json(q)
        {
          id:            q.id,
          survey_id:     q.survey_id,
          question_text: q.question_text,
          question_type: q.question_type,
          options:       q.options,
          position:      q.position,
          required:      q.required
        }
      end
    end
  end
end
