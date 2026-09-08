# One movement in the running account between Rally and a host organization.
#
# platform-payments-tickets.md Ticket F. Under the platform payment model the
# host is paid at capture, before the event runs, because ABA releases an
# uncaptured pre-auth after 30 days and registration opens months ahead (see
# docs/PAYWAY-PREAUTH-SPIKE.md §5). A refund after that point is money Rally
# has already passed on, so recovering it is a running balance rather than a
# reversal — which is exactly what this table is.
#
# **Append-only.** Updates and destroys are refused below. A mistake is
# corrected by writing a compensating entry, so the history stays a true
# record of what was believed when. That is the whole value of a ledger; an
# editable one is just a balance with extra steps.
#
# Nothing writes to this table yet — the gateway work it depends on is
# blocked (Ticket B). The model and its arithmetic landed early because they
# have no ABA dependency and the negative-balance question is much better
# answered now than in production.
class HostLedgerEntry < ApplicationRecord
  belongs_to :organization
  belongs_to :source, polymorphic: true, optional: true

  # Positive entries are owed to the host, negative to Rally.
  ENTRY_TYPES = {
    # A participant's payment captured and split; the host's share.
    "registration_capture" => :credit,
    # A refund Rally paid the participant out of its own funds, now being
    # recovered from the host.
    "refund_clawback" => :debit,
    # Money actually sent to the host's bank account, clearing the balance.
    "payout" => :debit,
    # A manual correction. Signed either way, always with a description.
    "adjustment" => :either
  }.freeze

  # Past this much owed to Rally, the balance stops being something that
  # will quietly net off against the host's next event and becomes a debt
  # someone has to chase. Deliberately a modest figure: the point is to
  # notice early, not to cap exposure.
  ARREARS_THRESHOLD_CENTS = 50_00

  validates :amount_cents, numericality: { other_than: 0 }
  validates :currency, presence: true
  validates :entry_type, inclusion: { in: ENTRY_TYPES.keys }
  validates :description, presence: true, if: -> { entry_type == "adjustment" }
  validate :amount_sign_matches_entry_type

  before_update { raise ActiveRecord::ReadOnlyRecord, "host ledger entries are append-only" }
  before_destroy { raise ActiveRecord::ReadOnlyRecord, "host ledger entries are append-only" }

  scope :credits, -> { where("amount_cents > 0") }
  scope :debits, -> { where("amount_cents < 0") }
  scope :newest_first, -> { order(created_at: :desc) }

  # The balance is deliberately a SUM over the entries rather than a cached
  # column on organizations. "First-class ledger, not a derived number"
  # (Ticket F) is about the *entries* being the record of truth — a cached
  # total is the thing that silently drifts away from them.
  def self.balance_cents(organization)
    where(organization: organization).sum(:amount_cents)
  end

  def credit?
    amount_cents.positive?
  end

  private

  # Catches the sign errors that would otherwise be indistinguishable from a
  # real movement — a clawback recorded as a credit pays the host twice.
  def amount_sign_matches_entry_type
    return if amount_cents.nil? || amount_cents.zero?

    case ENTRY_TYPES[entry_type]
    when :credit
      errors.add(:amount_cents, "must be positive for a #{entry_type}") unless amount_cents.positive?
    when :debit
      errors.add(:amount_cents, "must be negative for a #{entry_type}") unless amount_cents.negative?
    end
  end
end
