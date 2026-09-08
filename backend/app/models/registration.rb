class Registration < ApplicationRecord
  belongs_to :event
  belongs_to :user
  has_many :registration_answers, dependent: :destroy
  has_many :registration_event_types, dependent: :destroy
  has_many :event_types, through: :registration_event_types
  has_many :payments, dependent: :destroy
  # The platform-processed counterpart of #payments, used when the event is
  # Event#platform_processed?. Only ever one of the two is populated for a
  # given registration — which one is fixed by the event's payment_model.
  has_many :platform_payments, dependent: :destroy
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

  # Soft-delete — see RegistrationsController#destroy ("organizer removes
  # participant"), the main caller. Deliberately does NOT cascade-destroy
  # payment_answers/registration_event_types/payments/certificate/result the
  # way the old hard-delete's `dependent: :destroy` chain above did — that
  # was silently wiping a participant's own financial audit trail (Payments,
  # and now Refunds) the moment an organizer removed them, the same class of
  # problem the refund feature was built to avoid. #discard! leaves all of
  # that attached to the (now-hidden) registration instead.
  scope :kept, -> { where(deleted_at: nil) }
  scope :discarded, -> { where.not(deleted_at: nil) }

  validates :status, inclusion: { in: STATUSES }
  validates :payment_status, inclusion: { in: PAYMENT_STATUSES }
  validates :user_id, uniqueness: { scope: :event_id, message: "already registered for this event" }
  validate :event_not_full, on: :create

  # The refund policy is captured here rather than at each call site — unlike
  # amount_owed_cents below, which every creation path has to remember to
  # compute for itself (RegistrationsController, Waitlists::PromoteNext,
  # Registrations::GuestCheckout). Three places to forget is three places to
  # get it wrong, and a missing snapshot isn't visible until someone asks for
  # a refund months later.
  before_validation :snapshot_refund_policy, on: :create

  # Amount owed. `amount_owed_cents` is a snapshot taken once at creation
  # time (see Api::V1::RegistrationsController#compute_amount and
  # Waitlists::PromoteNext#compute_amount) so a still-unpaid registration
  # keeps owing what it owed when the participant registered, even if the
  # organizer changes the event/event-type price afterward — see
  # change-event-plan-tickets.md's "Ticket B". Rows created before this
  # column existed have no snapshot (nil) and fall back to the old
  # behavior of recomputing live from the *current* price.
  def owed_amount_cents
    amount_owed_cents || live_owed_amount_cents
  end

  # The policy this participant actually agreed to, frozen at checkout. Read
  # this, never event.refund_policy, when deciding what someone is owed.
  def refund_policy
    RefundPolicy.from(refund_policy_tiers)
  end

  # What this registration would get back if it were cancelled at `at`.
  #
  # Returns nil — not 0 — when no policy was in force, because "the host
  # never set a policy, so this is a human decision" and "the policy says
  # nothing comes back" are different answers, and only one of them can be
  # acted on automatically. Callers must handle nil explicitly.
  #
  # Evaluated against the event's *current* start_at rather than a snapshot
  # of it: the tiers are expressed relative to when the event starts, so if
  # an organizer moves the date, "up to 7 days before" should move with it.
  # Participants are told about date changes separately
  # (NotifyEventDetailsChangedJob).
  def refund_entitlement_cents(at: Time.current)
    policy = refund_policy
    return nil if policy.nil?

    policy.refund_amount_cents(amount_paid_cents, hours_until_start: hours_until_start(at))
  end

  def hours_until_start(at = Time.current)
    return nil if event&.start_at.nil?

    ((event.start_at - at) / 1.hour).floor
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

  # Soft-delete: sets status to "cancelled" too (same value a full refund
  # sets — see #apply_refund!) so the existing :active scope, and everything
  # built on it (Event#full?, #event_not_full below, EventType#full?), keeps
  # working unchanged — "does this hold a capacity slot" and "was this row
  # discarded" both collapse to the same status check. deleted_at is what
  # distinguishes *why* (moderation removal vs. refund) for anything that
  # needs to know, e.g. RegistrationsController#event_registrations hiding
  # discarded rows from the organizer's participant list while still
  # showing refund-cancelled ones.
  def discard!
    update!(deleted_at: Time.current, status: "cancelled")
  end

  def discarded?
    deleted_at.present?
  end

  # Whether this registration's participant wants a given non-essential
  # notification email — see Profile's notify_* columns
  # (notify_payment_received, notify_refund_issued,
  # notify_promoted_from_waitlist, notify_event_details_changed) and the
  # mailer call sites this gates (Refunds::IssueRefund,
  # Waitlists::PromoteNext, ProcessAbaPaywayWebhookJob,
  # PaymentsController#status, NotifyEventDetailsChangedJob). Opt-out, not
  # opt-in — defaults to true even if the profile row is somehow missing,
  # matching ProfilesController#profile_json's own default.
  def wants_notification?(type)
    user.profile&.public_send("notify_#{type}?") != false
  end

  private

  # Copies the event's policy onto this registration once, at creation.
  #
  # Guarded on nil? rather than present?: an explicitly non-refundable policy
  # is an empty array, and `[].present?` is false, so a present? check here
  # would re-copy it on every attempt and — worse — would let a caller's
  # deliberate [] be overwritten by the event's tiers.
  def snapshot_refund_policy
    return unless refund_policy_tiers.nil?

    self.refund_policy_tiers = event&.refund_policy_tiers
  end

  # Legacy path for rows with no amount_owed_cents snapshot — see
  # #owed_amount_cents above.
  def live_owed_amount_cents
    types = event_types.to_a
    return event.price_cents if types.empty?
    types.sum(&:effective_price_cents)
  end

  def event_not_full
    return unless event&.capacity
    # Use pessimistic locking to prevent race conditions in concurrent registrations
    # Lock the event row to ensure the capacity check and registration are atomic
    event.reload(lock: true)
    if event.registrations.active.count >= event.capacity
      # :event_full is a machine-readable code — see
      # RegistrationsController#create, which maps it to `code: "full"` in
      # the JSON response so the frontend can react (lock the UI, refresh
      # capacity) instead of just string-matching the message.
      errors.add(:base, :event_full, message: "This event is full")
    end
  end
end
