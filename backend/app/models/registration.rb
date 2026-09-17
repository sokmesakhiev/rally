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

  # Free-text search over who the participant is, for the organizer's list and
  # the check-in desk. Same shape as Event.search — `sanitize_sql_like` so a
  # name containing "%" or "_" searches for those characters rather than acting
  # as a wildcard, and the pattern bound rather than interpolated.
  #
  # Joins rather than subqueries because both tables are needed for display
  # anyway. `left_joins(user: :profile)`: a profile is auto-created with every
  # user (User#after_create) so an inner join would work today, but a LEFT JOIN
  # means a registration can never vanish from an organizer's list because of a
  # missing associated row — losing a paying participant from the view is a
  # far worse failure than showing one with a blank name.
  scope :search, ->(term) {
    query = term.to_s.strip
    next all if query.blank?

    pattern = "%#{sanitize_sql_like(query)}%"
    left_joins(user: :profile).where(
      "profiles.display_name ILIKE :pattern OR users.email ILIKE :pattern " \
      "OR registrations.bib_number ILIKE :pattern",
      pattern: pattern
    )
  }

  validates :status, inclusion: { in: STATUSES }
  validates :payment_status, inclusion: { in: PAYMENT_STATUSES }

  # Bib numbers (docs/partner-api-design.md, D10). Blank is stored as NULL, not
  # "" — the partial unique index keys on `bib_number IS NOT NULL`, so an empty
  # string would be a real value and the second runner to be cleared would
  # collide with the first.
  normalizes :bib_number, with: ->(value) { value.to_s.strip.presence }

  # Matches the partial unique index from
  # db/migrate/20260916010000_add_bib_number_to_registrations.rb. Unlike the
  # user_id rule below there is no `conditions:` for kept rows: the index isn't
  # scoped that way either, deliberately, so a withdrawn runner's number can't
  # be handed to someone else while their result and certificate still point at
  # it.
  validates :bib_number,
            uniqueness: { scope: :event_id, message: "is already taken for this event" },
            length: { maximum: 32 },
            allow_nil: true
  # Scoped to live rows, matching the partial unique index added in
  # db/migrate/20260909010000_scope_registration_uniqueness_to_kept.rb.
  # #discard! keeps the row (for its payment/refund history) but the person is
  # no longer registered, so they must be able to sign up again — whether they
  # were removed by an organizer or swept by Registrations::ReleaseAbandoned.
  # Without the `conditions:`, the model would reject what the database now
  # allows, which is the more confusing half of the bug.
  validates :user_id, uniqueness: {
    scope: :event_id,
    conditions: -> { where(deleted_at: nil) },
    message: "already registered for this event"
  }
  validate :event_not_full, on: :create
  # `on: :create` is the whole design of the "let in-flight registrations
  # finish" decision. A paid registration's row is written *before* the KHQR
  # payment succeeds (see RegistrationsController#create), so validating this
  # on every save would mean an organizer closing registration while someone
  # is at the payment screen causes the ABA webhook to fail when it tries to
  # mark them paid — taking their money and then refusing the spot. Closing
  # stops *new* sign-ups; it does not reach backwards.
  validate :registration_is_open, on: :create
  validate :event_not_suspended, on: :create

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

  # Legacy path for rows with no amount_owed_cents snapshot — see
  # #owed_amount_cents above.
  def live_owed_amount_cents
    types = event_types.to_a
    return event.price_cents if types.empty?
    types.sum(&:effective_price_cents)
  end

  # :registration_closed is a machine-readable code, same contract as
  # :event_full below — RegistrationsController maps it to `code:` in the JSON
  # so the frontend can render "the organizer closed registration" rather than
  # string-matching a sentence, and so it can tell that apart from "full"
  # (which offers the waitlist; this does not).
  def registration_is_open
    return if event.nil? || event.accepting_signups?

    errors.add(:base, :registration_closed, message: "Registration for this event is closed")
  end

  # A suspended event took no notice of sign-ups until now: `Event#suspend!`
  # freezes the *organizer* out (EventAuthorization::SUSPENDED_ALLOWED_CAPABILITIES)
  # and forces is_published false, but neither this model nor WaitlistEntry
  # looked at `suspended_at`, and neither RegistrationsController#set_event nor
  # the waitlist's checks published-ness — so anyone holding the event id could
  # still register for an event an admin had taken down, and take their money
  # with them.
  #
  # Its own error type rather than folding into `accepting_signups?`: an
  # organizer closing registration and an admin suspending the event are
  # different facts, and reporting a suspension as "registration is closed"
  # would send the participant to ask the organizer to reopen something the
  # organizer cannot reopen.
  #
  # `on: :create` for the same reason as the two rules above — a suspension
  # landing while someone is at the payment screen must not make the ABA
  # webhook fail when it marks them paid.
  def event_not_suspended
    return if event.nil? || !event.suspended?

    errors.add(:base, :event_suspended, message: "This event is not currently accepting registrations")
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
