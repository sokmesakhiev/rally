class Registration < ApplicationRecord
  belongs_to :event
  belongs_to :user
  has_many :registration_answers, dependent: :destroy
  has_many :registration_event_types, dependent: :destroy
  has_many :event_types, through: :registration_event_types
  has_many :payments, dependent: :destroy

  STATUSES = %w[confirmed cancelled].freeze
  PAYMENT_STATUSES = %w[unpaid paid refunded].freeze

  validates :status, inclusion: { in: STATUSES }
  validates :payment_status, inclusion: { in: PAYMENT_STATUSES }
  validates :user_id, uniqueness: { scope: :event_id, message: "already registered for this event" }
  validate :event_not_full, on: :create

  # Amount owed, computed from selected event types (falling back to the
  # flat event price when no types were selected / the event has none).
  def owed_amount_cents
    types = event_types.to_a
    return event.price_cents if types.empty?
    types.sum(&:effective_price_cents)
  end

  def latest_payment
    payments.order(created_at: :desc).first
  end

  # Called once an ABA PayWay payment is confirmed APPROVED.
  def mark_paid_from_payment!(payment)
    update!(payment_status: "paid", amount_paid_cents: amount_paid_cents + payment.amount_cents)
  end

  private

  def event_not_full
    return unless event&.capacity
    if event.registrations.count >= event.capacity
      errors.add(:base, "This event is full")
    end
  end
end
