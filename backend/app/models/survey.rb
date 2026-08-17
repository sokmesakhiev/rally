class Survey < ApplicationRecord
  belongs_to :creator, class_name: "User"
  has_one    :event, dependent: :nullify   # event.survey_id → nil on survey delete
  has_many   :survey_questions, -> { order(position: :asc) }, dependent: :destroy

  validates :title, presence: true, length: { maximum: 200 }

  accepts_nested_attributes_for :survey_questions,
    allow_destroy: true,
    reject_if: :all_blank

  scope :kept, -> { where(deleted_at: nil) }
  scope :discarded, -> { where.not(deleted_at: nil) }

  # Soft-delete — see SurveysController#destroy. `has_one :event,
  # dependent: :nullify` above only fires on a real #destroy!, which this
  # deliberately isn't, so the event → survey link is nullified explicitly
  # here instead: an event shouldn't keep pointing at a hidden survey.
  #
  # Uses a direct update_all on the foreign key (mirroring what Rails'
  # dependent: :nullify does internally) rather than `event&.update!(...)` —
  # going through the has_one reader/writer is unnecessary here and update_all
  # skips loading/validating a record we're about to discard anyway.
  def discard!
    transaction do
      Event.where(survey_id: id).update_all(survey_id: nil)
      update!(deleted_at: Time.current)
    end
  end

  def discarded?
    deleted_at.present?
  end
end
