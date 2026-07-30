require "rails_helper"

RSpec.describe "Survey Responses API", type: :request do
  let(:organizer) { create(:user) }
  let(:other)     { create(:user) }
  let(:survey)    { organizer.surveys.create!(title: "Race survey") }
  let(:event)     { create(:event, creator: organizer, survey: survey) }

  let!(:text_question) do
    survey.survey_questions.create!(
      question_text: "How did you hear about us?", question_type: "text", position: 0
    )
  end

  let!(:choice_question) do
    survey.survey_questions.create!(
      question_text: "T-shirt size",
      question_type: "single_choice",
      position: 1,
      options: [ { "id" => "s", "label" => "Small" }, { "id" => "m", "label" => "Medium" } ]
    )
  end

  describe "GET /api/v1/events/:event_id/survey_responses" do
    it "returns the survey summary and one entry per registration" do
      participant = create(:user)
      participant.profile.update!(display_name: "Alex Runner")
      registration = create(:registration, event: event, user: participant)
      registration.registration_answers.create!(survey_question: text_question, answer_text: "Instagram")
      registration.registration_answers.create!(survey_question: choice_question, answer_options: [ "m" ])

      get "/api/v1/events/#{event.id}/survey_responses",
          headers: auth_headers(organizer),
          as: :json

      expect(response).to have_http_status(:ok)

      expect(json["survey"]["id"]).to eq(survey.id)
      expect(json["survey"]["title"]).to eq("Race survey")
      expect(json["survey"]["questions"].map { |q| q["question_text"] })
        .to eq([ "How did you hear about us?", "T-shirt size" ])

      expect(json["responses"].size).to eq(1)
      resp = json["responses"].first
      expect(resp["registration_id"]).to eq(registration.id)
      expect(resp["user"]["display_name"]).to eq("Alex Runner")
      expect(resp["user"]["email"]).to eq(participant.email)

      answers = resp["answers"]
      expect(answers.find { |a| a["survey_question_id"] == text_question.id }["answer_text"])
        .to eq("Instagram")
      expect(answers.find { |a| a["survey_question_id"] == choice_question.id }["answer_options"])
        .to eq([ "m" ])
    end

    it "orders questions in the survey summary by position, not insertion order" do
      # Created last but positioned first, so insertion order and position
      # order disagree — the response must follow position.
      first = survey.survey_questions.create!(
        question_text: "Emergency contact", question_type: "text", position: 0
      )
      text_question.update!(position: 1)
      choice_question.update!(position: 2)

      get "/api/v1/events/#{event.id}/survey_responses", headers: auth_headers(organizer), as: :json

      expect(json["survey"]["questions"].map { |q| q["id"] })
        .to eq([ first.id, text_question.id, choice_question.id ])
    end

    it "includes registrations that answered nothing, with an empty answers array" do
      # An organizer still needs to see who registered even if the survey was
      # optional and they skipped it — dropping them would understate signups.
      registration = create(:registration, event: event)

      get "/api/v1/events/#{event.id}/survey_responses", headers: auth_headers(organizer), as: :json

      expect(json["responses"].map { |r| r["registration_id"] }).to include(registration.id)
      expect(json["responses"].first["answers"]).to eq([])
    end

    it "returns an empty responses array when the event has no survey attached" do
      no_survey_event = create(:event, creator: organizer, survey: nil)

      get "/api/v1/events/#{no_survey_event.id}/survey_responses",
          headers: auth_headers(organizer),
          as: :json

      expect(response).to have_http_status(:ok)
      expect(json["responses"]).to eq([])
      expect(json["survey"]).to be_nil
    end

    it "returns 404 when a non-organizer asks for the responses" do
      # Scoped through current_user.events, so someone else's event simply
      # isn't found — this is the access-control check for participants' answers.
      create(:registration, event: event)

      get "/api/v1/events/#{event.id}/survey_responses", headers: auth_headers(other), as: :json

      expect(response).to have_http_status(:not_found)
    end

    it "returns 404 for an unknown event id" do
      get "/api/v1/events/#{SecureRandom.uuid}/survey_responses",
          headers: auth_headers(organizer),
          as: :json

      expect(response).to have_http_status(:not_found)
    end

    it "requires authentication" do
      get "/api/v1/events/#{event.id}/survey_responses", as: :json

      expect(response).to have_http_status(:unauthorized)
    end
  end
end
