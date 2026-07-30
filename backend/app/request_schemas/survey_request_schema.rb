# frozen_string_literal: true

# Shared by both POST /api/v1/surveys and PATCH /api/v1/surveys/:id — unlike
# EventRequestSchema/EventUpdateRequestSchema, create and update genuinely
# take the same optional shape here (title falls back to a default on
# create same as it's left alone on update; a survey can exist with zero
# questions in both cases), so one class covers both rather than two
# near-duplicates. Params are top-level (not nested under a "survey" key)
# — matches what surveysApi.create/update actually post.
#
# SurveysController#update tells "questions omitted" (leave existing
# questions alone) apart from "questions: []" (replace with none) via
# `validated_params.key?(:questions)` — that only works because dry-schema
# leaves an absent optional key out of the output entirely rather than
# filling it in as nil/[]; see EventUpdateRequestSchema's class comment for
# the same behavior relied on there.
#
# The choice-question "must have >= 2 options" rule (SurveyQuestion#
# options_present_for_choice_questions) stays model-only — it depends on
# question_type, which this schema validates the shape of but doesn't
# reason about together with options.
class SurveyRequestSchema < ApplicationRequestSchema
  params do
    optional(:title).maybe(:string)
    optional(:questions).array(:hash) do
      required(:question_text).filled(:string)
      optional(:question_type).filled(:string, included_in?: SurveyQuestion::TYPES)
      optional(:options).array(:hash) do
        required(:id).filled(:string)
        required(:label).filled(:string)
      end
      optional(:required).filled(:bool)
    end
  end
end
