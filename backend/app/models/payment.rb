class Payment < ApplicationRecord
  belongs_to :registration
  has_many :refunds, dependent: :destroy

  # partially_refunded sits between approved and refunded — still a valid,
  # completed payment, just with some money returned. refunded means fully
  # refunded (refunded_amount_cents == amount_cents); see #fully_refunded?.
  STATUSES = %w[pending approved declined cancelled expired partially_refunded refunded].freeze

  validates :provider, presence: true
  validates :tran_id, presence: true, uniqueness: true
  validates :status, inclusion: { in: STATUSES }
  validates :amount_cents, numericality: { greater_than: 0 }
  validates :currency, presence: true
  validates :refunded_amount_cents,
    numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: :amount_cents }

  scope :pending, -> { where(status: "pending") }

  def approved?
    status == "approved"
  end

  def pending?
    status == "pending"
  end

  def expired?
    expires_at.present? && expires_at < Time.current
  end

  def fully_refunded?
    refunded_amount_cents >= amount_cents
  end

  def partially_refunded?
    refunded_amount_cents.positive? && !fully_refunded?
  end

  # A payment only has money to give back once ABA has actually confirmed it
  # (approved), and only up to whatever hasn't already gone back.
  def refundable?
    (status == "approved" || status == "partially_refunded") && remaining_refundable_cents.positive?
  end

  def remaining_refundable_cents
    amount_cents - refunded_amount_cents
  end

  # ABA amounts are formatted differently per currency: KHR has no decimal
  # places, everything else (USD) uses 2 decimal places.
  def formatted_amount
    if currency.to_s.casecmp("khr").zero?
      (amount_cents / 100.0).round.to_s
    else
      format("%.2f", amount_cents / 100.0)
    end
  end
end
