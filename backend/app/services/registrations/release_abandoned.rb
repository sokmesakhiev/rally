# frozen_string_literal: true

module Registrations
  # Releases capacity held by paid-event registrations that were created and
  # then abandoned before payment.
  #
  # `RegistrationsController#create` writes the Registration row (status
  # "confirmed", payment_status "unpaid") as soon as the guest/type/survey
  # steps are done, *before* any KHQR payment succeeds — and
  # `Registration::active`, which `Event#full?` and `#event_not_full` both
  # count, excludes only cancelled rows. So an unpaid registration holds a real
  # slot. Nothing previously reversed that: `Payment#expired?` and
  # `PaymentsController#refresh_if_stale!` mark the *Payment* expired and never
  # touch the registration. On a capacity-limited event, abandoned checkouts
  # could silently consume the whole thing.
  #
  # Run hourly from config/recurring.yml via ReleaseAbandonedRegistrationsJob.
  class ReleaseAbandoned
    # An hour past the last payment attempt (or past the registration itself,
    # when the payment screen was never opened).
    #
    # The KHQR code expires after 15 minutes
    # (Payments::CreatePayment::PAYMENT_LIFETIME_MINUTES), so an hour is well
    # clear of any legitimately in-flight payment while still freeing the slot
    # within the same sitting. The margin matters: ABA's webhook can arrive
    # late, and cancelling a registration somebody actually paid for is far
    # worse than holding a slot slightly too long.
    GRACE_PERIOD = 1.hour

    # Payment statuses that mean money actually moved. A registration with one
    # of these is never a sweep candidate, whatever its payment_status column
    # says.
    #
    # Deliberately one constant used by BOTH the candidate query and the
    # re-check under the lock. They were two separate lists, and the re-check's
    # was narrower — a refund landing mid-sweep would have been caught by the
    # query but missed by the guard. In practice the payment_status check would
    # have covered it, but that's a coupling between two unrelated pieces of
    # state, not a guarantee.
    SETTLED_PAYMENT_STATUSES = %w[approved partially_refunded refunded].freeze

    Result = Struct.new(:released, :promoted, keyword_init: true)

    def self.call(...)
      new(...).call
    end

    def initialize(grace_period: GRACE_PERIOD, now: Time.current)
      @grace_period = grace_period
      @now = now
    end

    def call
      cutoff = @now - @grace_period
      released = 0
      events = Set.new

      # Safe to mutate rows mid-iteration: find_each pages by ascending id, and
      # discarding a row only removes it from a set we've already passed.
      candidates(cutoff).find_each do |registration|
        next unless release(registration, cutoff)

        released += 1
        events << registration.event_id
      end

      # Promotion happens once per event after the sweep, not once per
      # registration. Releasing three slots on one event should walk the
      # waitlist once and fill all three, rather than running the whole
      # promotion pass three times.
      promoted = events.sum { |event_id| promote(event_id) }

      Result.new(released: released, promoted: promoted)
    end

    private

    # Deliberately narrow. Every clause is load-bearing:
    #
    #   kept / active   — don't re-process something already released.
    #   payment_status  — "unpaid" is the whole signal. Free registrations are
    #                     created as "paid" (RegistrationsController#create and
    #                     Waitlists::PromoteNext both set it from the amount),
    #                     so they can never match. If that default ever
    #                     changes, this job would start cancelling every free
    #                     registration — hence the spec that pins it.
    #   no approved payment — belt and braces against payment_status lagging
    #                     behind an approved Payment row.
    #
    # The time comparison uses the newest payment's created_at, falling back to
    # the registration's own — a participant who opened the payment screen
    # twenty minutes ago hasn't abandoned anything yet, even if they registered
    # hours earlier.
    # NOT EXISTS, not `where.not(id: subquery)`. The latter compiles to
    # `id NOT IN (SELECT registration_id ...)`, and SQL's NOT IN evaluates to
    # NULL — matching nothing at all — the moment the subquery returns a single
    # NULL. `payments.registration_id` is NOT NULL today, so that can't happen
    # yet; the reason to avoid it anyway is the failure mode. A sweep that
    # silently stops releasing anything looks exactly like a sweep with nothing
    # to do. NOT EXISTS is null-safe by construction and generally plans better
    # on Postgres besides.
    def candidates(cutoff)
      Registration
        .kept
        .active
        .where(payment_status: "unpaid")
        .where(
          "NOT EXISTS (SELECT 1 FROM payments WHERE payments.registration_id = registrations.id " \
          "AND payments.status IN (?))",
          SETTLED_PAYMENT_STATUSES
        )
        .where(
          "COALESCE((SELECT MAX(payments.created_at) FROM payments " \
          "WHERE payments.registration_id = registrations.id), registrations.created_at) < ?",
          cutoff
        )
    end

    # Re-checked inside a row lock before discarding. The query above ran at
    # some earlier moment, and an ABA webhook can approve a payment in the gap
    # — this is the difference between "usually fine" and "never cancels a
    # payment that landed."
    def release(registration, cutoff)
      released = false

      # `next`, not `return` — returning out of a transaction block from inside
      # it is a good way to end up arguing about whether the transaction
      # committed.
      registration.with_lock do
        next if registration.payment_status != "unpaid"
        next if registration.payments.where(status: SETTLED_PAYMENT_STATUSES).exists?
        next if last_activity_at(registration) >= cutoff

        registration.discard!
        released = true
      end

      released
    end

    def last_activity_at(registration)
      registration.payments.maximum(:created_at) || registration.created_at
    end

    def promote(event_id)
      event = Event.find_by(id: event_id)
      return 0 if event.nil?

      Waitlists::PromoteNext.call(event).size
    end
  end
end
