require "rails_helper"

RSpec.describe Survey do
  let(:creator) { create(:user) }

  describe "validations" do
    it "is valid with a title" do
      expect(creator.surveys.build(title: "Race survey")).to be_valid
    end

    it "requires a title" do
      expect(creator.surveys.build(title: nil)).not_to be_valid
      expect(creator.surveys.build(title: "")).not_to be_valid
    end

    it "rejects a title longer than 200 characters" do
      expect(creator.surveys.build(title: "a" * 201)).not_to be_valid
      expect(creator.surveys.build(title: "a" * 200)).to be_valid
    end
  end

  describe "associations" do
    it "orders survey_questions by position" do
      survey = creator.surveys.create!(title: "Ordered")
      survey.survey_questions.create!(question_text: "Third?",  question_type: "text", position: 2)
      survey.survey_questions.create!(question_text: "First?",  question_type: "text", position: 0)
      survey.survey_questions.create!(question_text: "Second?", question_type: "text", position: 1)

      expect(survey.reload.survey_questions.map(&:question_text))
        .to eq([ "First?", "Second?", "Third?" ])
    end

    it "destroys its questions when destroyed" do
      survey = creator.surveys.create!(title: "Doomed")
      survey.survey_questions.create!(question_text: "Q?", question_type: "text", position: 0)

      expect { survey.destroy! }.to change(SurveyQuestion, :count).by(-1)
    end

    it "nullifies the attached event's survey_id rather than destroying the event" do
      # dependent: :nullify — deleting a survey must never cascade into
      # deleting an event (and its registrations) that merely referenced it.
      survey = creator.surveys.create!(title: "Attached")
      event = create(:event, creator: creator, survey: survey)

      expect { survey.destroy! }.not_to change(Event, :count)
      expect(event.reload.survey_id).to be_nil
    end
  end
end

RSpec.describe SurveyQuestion do
  let(:survey) { create(:user).surveys.create!(title: "Survey") }

  def build_question(**attrs)
    survey.survey_questions.build(
      { question_text: "How did you hear about us?", question_type: "text", position: 0 }.merge(attrs)
    )
  end

  describe "validations" do
    it { expect(build_question).to be_valid }

    it "requires question_text" do
      expect(build_question(question_text: nil)).not_to be_valid
    end

    it "rejects question_text longer than 500 characters" do
      expect(build_question(question_text: "a" * 501)).not_to be_valid
      expect(build_question(question_text: "a" * 500)).to be_valid
    end

    it "only accepts known question types" do
      SurveyQuestion::TYPES.each do |type|
        options = type == "text" ? [] : [ { "id" => "a", "label" => "A" }, { "id" => "b", "label" => "B" } ]
        expect(build_question(question_type: type, options: options)).to be_valid
      end

      expect(build_question(question_type: "essay")).not_to be_valid
    end

    it "requires a non-negative integer position" do
      expect(build_question(position: -1)).not_to be_valid
      expect(build_question(position: 0)).to be_valid
    end

    it "defaults options to an empty array" do
      expect(build_question.options).to eq([])
    end
  end

  describe "#options_present_for_choice_questions" do
    it "allows a text question with no options" do
      expect(build_question(question_type: "text", options: [])).to be_valid
    end

    it "requires at least 2 options for a single_choice question" do
      expect(build_question(question_type: "single_choice", options: [])).not_to be_valid
      expect(
        build_question(question_type: "single_choice", options: [ { "id" => "s", "label" => "S" } ])
      ).not_to be_valid
      expect(
        build_question(
          question_type: "single_choice",
          options: [ { "id" => "s", "label" => "S" }, { "id" => "m", "label" => "M" } ]
        )
      ).to be_valid
    end

    it "requires at least 2 options for a multiple_choice question" do
      expect(build_question(question_type: "multiple_choice", options: [])).not_to be_valid
      expect(
        build_question(
          question_type: "multiple_choice",
          options: [ { "id" => "a", "label" => "A" }, { "id" => "b", "label" => "B" } ]
        )
      ).to be_valid
    end
  end
end

RSpec.describe RegistrationAnswer do
  let(:survey)       { create(:user).surveys.create!(title: "Survey") }
  let(:event)        { create(:event, survey: survey) }
  let(:registration) { create(:registration, event: event) }

  def choice_question(required: false, type: "single_choice")
    survey.survey_questions.create!(
      question_text: "T-shirt size",
      question_type: type,
      position: 0,
      required: required,
      options: [ { "id" => "s", "label" => "Small" }, { "id" => "m", "label" => "Medium" } ]
    )
  end

  def text_question(required: false)
    survey.survey_questions.create!(
      question_text: "Anything else?", question_type: "text", position: 0, required: required
    )
  end

  describe "required answers" do
    it "rejects a blank answer_text for a required text question" do
      q = text_question(required: true)

      answer = registration.registration_answers.build(survey_question: q, answer_text: "")

      expect(answer).not_to be_valid
      expect(answer.errors[:answer_text]).to be_present
    end

    it "allows a blank answer_text for an optional text question" do
      q = text_question(required: false)

      expect(registration.registration_answers.build(survey_question: q, answer_text: "")).to be_valid
    end

    it "rejects empty answer_options for a required choice question" do
      q = choice_question(required: true)

      answer = registration.registration_answers.build(survey_question: q, answer_options: [])

      expect(answer).not_to be_valid
      expect(answer.errors[:answer_options]).to be_present
    end
  end

  describe "#valid_options_selected" do
    it "rejects an option id that isn't offered by the question" do
      q = choice_question

      answer = registration.registration_answers.build(survey_question: q, answer_options: [ "xl" ])

      expect(answer).not_to be_valid
      expect(answer.errors[:answer_options].join).to include("xl")
    end

    it "accepts an offered option id" do
      q = choice_question

      expect(
        registration.registration_answers.build(survey_question: q, answer_options: [ "s" ])
      ).to be_valid
    end

    it "rejects more than one selection on a single_choice question" do
      q = choice_question(type: "single_choice")

      answer = registration.registration_answers.build(survey_question: q, answer_options: [ "s", "m" ])

      expect(answer).not_to be_valid
    end

    it "accepts multiple selections on a multiple_choice question" do
      q = choice_question(type: "multiple_choice")

      expect(
        registration.registration_answers.build(survey_question: q, answer_options: [ "s", "m" ])
      ).to be_valid
    end
  end

  describe "uniqueness" do
    it "allows only one answer per question per registration" do
      q = text_question
      registration.registration_answers.create!(survey_question: q, answer_text: "First")

      duplicate = registration.registration_answers.build(survey_question: q, answer_text: "Second")

      expect(duplicate).not_to be_valid
    end
  end
end
