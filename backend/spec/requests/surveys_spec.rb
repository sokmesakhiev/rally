require "rails_helper"

RSpec.describe "Surveys API", type: :request do
  let(:organizer) { create(:user) }
  let(:other)     { create(:user) }

  let(:valid_questions) do
    [
      { question_text: "How did you hear about us?", question_type: "text", required: false },
      {
        question_text: "T-shirt size",
        question_type: "single_choice",
        required: true,
        options: [ { id: "s", label: "Small" }, { id: "m", label: "Medium" } ]
      }
    ]
  end

  # ── POST /api/v1/surveys ──────────────────────────────────────────────────────
  describe "POST /api/v1/surveys" do
    it "creates a survey with questions" do
      post "/api/v1/surveys",
           params: { title: "Race Survey", questions: valid_questions },
           headers: auth_headers(organizer),
           as: :json

      expect(response).to have_http_status(:created)
      expect(json["survey"]["title"]).to eq("Race Survey")
      expect(json["survey"]["questions"].size).to eq(2)
    end

    it "defaults the title when omitted" do
      post "/api/v1/surveys", params: { questions: [] }, headers: auth_headers(organizer), as: :json

      expect(response).to have_http_status(:created)
      expect(json["survey"]["title"]).to eq("Registration Survey")
    end

    it "creates a survey with no questions at all" do
      post "/api/v1/surveys", params: {}, headers: auth_headers(organizer), as: :json

      expect(response).to have_http_status(:created)
      expect(json["survey"]["questions"]).to eq([])
    end

    it "returns 422 for a question missing question_text" do
      post "/api/v1/surveys",
           params: { questions: [ { question_type: "text" } ] },
           headers: auth_headers(organizer),
           as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(json["error"]).to be_present
    end

    it "returns 422 for an unknown question_type" do
      post "/api/v1/surveys",
           params: { questions: [ { question_text: "X?", question_type: "essay" } ] },
           headers: auth_headers(organizer),
           as: :json

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "returns 422 (model-level) when a choice question has fewer than 2 options" do
      post "/api/v1/surveys",
           params: {
             questions: [
               { question_text: "Size?", question_type: "single_choice", options: [ { id: "s", label: "Small" } ] }
             ]
           },
           headers: auth_headers(organizer),
           as: :json

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "returns 401 without a token" do
      post "/api/v1/surveys", params: { title: "X" }, as: :json
      expect(response).to have_http_status(:unauthorized)
    end
  end

  # ── GET /api/v1/surveys/:id ───────────────────────────────────────────────────
  #
  # A survey is readable only by the organizer who created it.
  #
  # This section exists because its absence was the bug. `#show` shares
  # `set_survey` with `#update`/`#destroy` — an unscoped
  # `Survey.kept.find(params[:id])` — but was left off the `authorize_owner!`
  # filter, so any authenticated account could read any survey it could name,
  # questions and options included. Every other action on the controller had a
  # spec; the unspecced one is where the missing `before_action` hid.
  #
  # The owner-reads and no-token examples flanking the refusal are positive
  # controls, not padding. A lone "a stranger is refused" assertion passes just
  # as happily when the endpoint is broken for everybody, and this codebase has
  # been caught by that twice — once against a 502, once against a JSON key
  # that didn't exist. Keep all three.
  describe "GET /api/v1/surveys/:id" do
    let!(:survey) { organizer.surveys.create!(title: "Internal draft") }

    before do
      survey.survey_questions.create!(
        question_text: "Which corporate sponsor sent you?",
        question_type: "text",
        position: 0
      )
    end

    # Positive control. If adding the guard breaks this, the fix was too broad.
    it "lets the owner read their own survey, questions and all" do
      get "/api/v1/surveys/#{survey.id}", headers: auth_headers(organizer), as: :json

      expect(response).to have_http_status(:ok)
      expect(json["survey"]["title"]).to eq("Internal draft")
      expect(json["survey"]["questions"].size).to eq(1)
    end

    # 403 rather than 404, matching `authorize_owner!` as the PATCH and DELETE
    # sections below already use it. Consistency inside this controller beat
    # the 404-for-strangers convention `EventAuthorization` uses; flip both
    # together if you'd rather not confirm the id exists.
    it "does not let a different signed-in user read it" do
      get "/api/v1/surveys/#{survey.id}", headers: auth_headers(other), as: :json

      expect(response).to have_http_status(:forbidden)
      # The status is the convention; *this* is the security property, and it
      # is what should still hold if someone later decides on 404 instead.
      expect(response.body).not_to include("Which corporate sponsor sent you?")
      expect(response.body).not_to include("Internal draft")
    end

    it "returns 401 without a token" do
      get "/api/v1/surveys/#{survey.id}", as: :json

      expect(response).to have_http_status(:unauthorized)
    end
  end

  # ── PATCH /api/v1/surveys/:id ─────────────────────────────────────────────────
  describe "PATCH /api/v1/surveys/:id" do
    let!(:survey) { create(:user).surveys.create!(title: "Old title") }

    it "updates the title without touching questions when questions is omitted" do
      survey.survey_questions.create!(question_text: "Existing?", question_type: "text", position: 0)

      patch "/api/v1/surveys/#{survey.id}",
            params: { title: "New title" },
            headers: auth_headers(survey.creator),
            as: :json

      expect(response).to have_http_status(:ok)
      expect(json["survey"]["title"]).to eq("New title")
      expect(json["survey"]["questions"].size).to eq(1)
    end

    it "replaces all questions when questions is present" do
      survey.survey_questions.create!(question_text: "Old question?", question_type: "text", position: 0)

      patch "/api/v1/surveys/#{survey.id}",
            params: { questions: valid_questions },
            headers: auth_headers(survey.creator),
            as: :json

      expect(response).to have_http_status(:ok)
      texts = json["survey"]["questions"].map { |q| q["question_text"] }
      expect(texts).to contain_exactly(*valid_questions.map { |q| q[:question_text] })
    end

    it "clears all questions when questions: [] is sent explicitly" do
      survey.survey_questions.create!(question_text: "Old question?", question_type: "text", position: 0)

      patch "/api/v1/surveys/#{survey.id}",
            params: { questions: [] },
            headers: auth_headers(survey.creator),
            as: :json

      expect(response).to have_http_status(:ok)
      expect(json["survey"]["questions"]).to eq([])
    end

    it "returns 403 when a different user tries to update" do
      patch "/api/v1/surveys/#{survey.id}",
            params: { title: "Hijacked" },
            headers: auth_headers(other),
            as: :json

      expect(response).to have_http_status(:forbidden)
    end
  end

  # ── DELETE /api/v1/surveys/:id ────────────────────────────────────────────────
  describe "DELETE /api/v1/surveys/:id" do
    let!(:survey) { create(:user).surveys.create!(title: "Doomed") }

    it "soft-deletes the survey rather than destroying the row" do
      delete "/api/v1/surveys/#{survey.id}", headers: auth_headers(survey.creator), as: :json

      expect(response).to have_http_status(:ok)
      expect(Survey.kept.find_by(id: survey.id)).to be_nil
      expect(survey.reload.discarded?).to be(true)
    end
  end
end
