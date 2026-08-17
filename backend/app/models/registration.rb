class Registration < ApplicationRecord
  belongs_to :event
  belongs_to :user
  has_many :registration_answers, dependent: :destroy
  has_many :registration_event_types, dependent: :destroy
  has_many :event_types, through: :registration_event_types
  has_many :payments, dependent: :destroy
  has_one :certificate, dependent: :destroy
  has_one :result, dependent: :destroy

  STATUSES = %w[confirmed cancelled].freeze
  PAYMENT_STATUSES = %w[unpaid paid partially_refunded refunded].freeze

  # A cancelled registration (today: only reachable via a full refund — see
  # Refunds::IssueRefund) no longer holds a capacity slot. Kept as a row
  # rather than destroyed (unlike RegistrationsController#destroy's "remove
  # participant", a hard delete) so its Payments/Refunds survive as an audit
  # trail. Event#full?, #event_not_full below, and EventType#full? all need
  # to agree on this same definition of "still holding a spot".
  scope :active, -> { where.not(status: "cancelled") }

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

  def checked_in?
    checked_in_at.present?
  end

  # Called once an ABA PayWay payment is confirmed APPROVED.
  def mark_paid_from_payment!(payment)
    update!(payment_status: "paid", amount_paid_cents: amount_paid_cents + payment.amount_cents)
  end

  # Called by Refunds::IssueRefund after a Refund succeeds. `full` mirrors
  # Payment#fully_refunded? for the specific payment being refunded — a
  # registration can have more than one Payment (e.g. a failed/expired
  # attempt followed by a successful one), so "this payment is fully
  # refunded" isn't quite the same question as "this registration owes
  # nothing further"; the caller decides which applies.
  #
  # Cancelling frees the capacity slot (see the :active scope above) — the
  # caller is responsible for offering it to the waitlist afterwards
  # (Waitlists::PromoteNext), same as RegistrationsController#destroy does.
  def apply_refund!(amount_cents, full:)
    update!(
      amount_paid_cents: [ amount_paid_cents - amount_cents, 0 ].max,
      payment_status: full ? "refunded" : "partially_refunded",
      status: full ? "cancelled" : status
    )
  end

  private

  def event_not_full
    return unless event&.capacity
    if event.registrations.active.count >= event.capacity
      # :event_full is a machine-readable code — see
      # RegistrationsController#create, which maps it to `code: "full"` in
      # the JSON response so the frontend can react (lock the UI, refresh
      # capacity) instead of just string-matching the message.
      errors.add(:base, :event_full, message: "This event is full")
    end
  end
end
