# One row per refund attempt against a Payment (a single Payment can have
# several — ABA PayWay allows multiple partial refunds up to the total paid,
# see AbaPayway::Client#refund). Kept as its own table rather than columns on
# Payment so the audit trail (who, when, how much, via which method, ABA's
# raw response) survives even across multiple refunds on the same payment.
class Refund < ApplicationRecord
  belongs_to :payment
  belongs_to :initiated_by, class_name: "User"

  # gateway: issued through AbaPayway::Client#refund, money moves via ABA.
  # manual:  logged only — the organizer/admin already refunded the payer
  #          outside Rally (bank transfer, cash, a gateway refund issued
  #          directly in ABA's own merchant portal) and this just records it
  #          so Payment/Registration state and event capacity stay accurate.
  METHODS = %w[gateway manual].freeze

  # pending: reserved for a gateway call that's in flight — in practice
  #          Refunds::IssueRefund only ever persists a Refund once it already
  #          knows the outcome (ABA's refund call is synchronous), so this
  #          exists mainly so the state machine isn't artificially missing a
  #          step if that ever changes (e.g. an async retry path later).
  # succeeded / failed: terminal states.
  STATUSES = %w[pending succeeded failed].freeze

  validates :amount_cents, numericality: { greater_than: 0 }
  validates :refund_method, inclusion: { in: METHODS }
  validates :status, inclusion: { in: STATUSES }
  # Manual refunds bypass the gateway entirely, so a reason is the only
  # record of why money left the books — require it. Gateway refunds are
  # already self-explanatory via ABA's raw_response, so a reason there is a
  # nice-to-have, not required.
  validates :reason, presence: true, if: -> { refund_method == "manual" }

  def succeeded?
    status == "succeeded"
  end

  # Mirrors Payment#formatted_amount (currency-aware cents formatting) —
  # duplicated rather than delegated since Payment's version is an instance
  # method keyed off its own amount_cents/currency, not reusable as-is for a
  # different amount against the same currency.
  def formatted_amount
    if payment.currency.to_s.casecmp("khr").zero?
      (amount_cents / 100.0).round.to_s
    else
      format("%.2f", amount_cents / 100.0)
    end
  end
end
