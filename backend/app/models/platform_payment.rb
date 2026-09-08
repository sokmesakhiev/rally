# A participant paying Rally for a registration, with the capture split
# between Rally's commission and the host's share.
#
# Deliberately separate from Payment, which records the older (and still
# current, for `Event#direct_to_organizer?` events) arrangement where the
# money goes straight to the organizer's own merchant account and Rally is
# never in the payment path. Both models coexist indefinitely: events created
# before the platform flow shipped keep settling directly.
#
# See platform-payments-tickets.md Ticket C.
class PlatformPayment < ApplicationRecord
  belongs_to :registration

  # The lifecycle, in the order it actually happens:
  #
  #   pending    — row opened, pre-auth QR requested, participant hasn't paid
  #   authorized — participant paid; ABA is holding the funds, uncaptured
  #   captured   — completed with payout; Rally and the host have both been paid
  #
  # and the ways it ends instead:
  #
  #   declined   — the gateway refused the pre-auth
  #   cancelled  — the hold was released deliberately
  #   expired    — the hold aged out (see AUTHORIZATION_WINDOW)
  #   partially_refunded / refunded — money has gone back after capture
  #
  # Ticket C's own description starts this list at `authorized`. `pending` and
  # `declined` are added because there is a real window between "we asked
  # PayWay for a pre-auth QR" and "the participant paid it" — exactly the
  # window Payment models with its own `pending`. Without them, an abandoned
  # or refused pre-auth leaves no row at all, which is precisely the
  # reconciliation hole this table exists to close.
  STATUSES = %w[
    pending authorized captured declined cancelled expired
    partially_refunded refunded
  ].freeze

  # ABA auto-cancels an uncaptured pre-auth after 30 days, returning the funds
  # to the payer. This is a hard ceiling, not a Rally policy: it's why the
  # host is necessarily paid before the event rather than after it, and
  # therefore why a refund has to be a clawback (Ticket F) rather than a
  # reversal of money Rally still holds. Registration opens months ahead of a
  # typical event, so "hold the funds until the event is over" is not
  # buildable on pre-auth. See docs/PAYWAY-PREAUTH-SPIKE.md §5.
  AUTHORIZATION_WINDOW = 30.days

  validates :provider, presence: true
  validates :tran_id, presence: true, uniqueness: true
  validates :status, inclusion: { in: STATUSES }
  validates :currency, presence: true
  validates :gross_amount_cents, numericality: { greater_than: 0 }
  validates :platform_fee_cents, numericality: { greater_than_or_equal_to: 0 }
  validates :host_net_cents, numericality: { greater_than_or_equal_to: 0 }
  validates :refunded_amount_cents,
    numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: :gross_amount_cents }
  validate :split_sums_to_gross

  scope :pending, -> { where(status: "pending") }
  scope :authorized, -> { where(status: "authorized") }
  scope :captured, -> { where(status: "captured") }

  def pending?
    status == "pending"
  end

  def authorized?
    status == "authorized"
  end

  def captured?
    status == "captured"
  end

  # No bare #expired?, on purpose. Payment has one, but it means "the QR
  # window elapsed" while also sitting next to an `expired` *status* — an
  # ambiguity that's harmless there and would not be here, because this model
  # has two unrelated clocks. Ask for the one you mean.
  def qr_expired?
    expires_at.present? && expires_at < Time.current
  end

  def hold_expired?
    hold_expires_at.present? && hold_expires_at < Time.current
  end

  def fully_refunded?
    refunded_amount_cents >= gross_amount_cents
  end

  def partially_refunded?
    refunded_amount_cents.positive? && !fully_refunded?
  end

  # There is only money to give back once the split has actually been
  # captured — an authorized-but-uncaptured hold is released, not refunded.
  def refundable?
    (captured? || status == "partially_refunded") && remaining_refundable_cents.positive?
  end

  def remaining_refundable_cents
    gross_amount_cents - refunded_amount_cents
  end

  private

  # Mirrored by a CHECK constraint of the same name in the migration. Both,
  # not either: the constraint is what survives update_column and friends,
  # and this is what produces a usable error message instead of a
  # StatementInvalid.
  def split_sums_to_gross
    return if [ gross_amount_cents, platform_fee_cents, host_net_cents ].any?(&:nil?)
    return if gross_amount_cents == platform_fee_cents + host_net_cents

    errors.add(
      :base, :split_mismatch,
      message: "platform fee (#{platform_fee_cents}) plus host net (#{host_net_cents}) " \
               "must equal the gross amount (#{gross_amount_cents})"
    )
  end
end
