class Payment < ApplicationRecord
  belongs_to :registration

  STATUSES = %w[pending approved declined cancelled expired refunded].freeze

  validates :provider, presence: true
  validates :tran_id, presence: true, uniqueness: true
  validates :status, inclusion: { in: STATUSES }
  validates :amount_cents, numericality: { greater_than: 0 }
  validates :currency, presence: true

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
