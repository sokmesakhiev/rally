# frozen_string_literal: true

module Waitlists
  # Called whenever a registration going away might have freed up a spot
  # (today: RegistrationsController#destroy — an organizer removing a
  # participant; the not-yet-built refund workflow should call this too once
  # it exists, since a refund frees the same capacity a removal does).
  #
  # Walks the event's waitlist in FIFO order (oldest #created_at first) and
  # converts each entry that now fits into a real, "auto-promoted"
  # Registration — same shape RegistrationsController#create would have
  # built, plus a distinct confirmation email (RegistrationMailer
  # #promoted_from_waitlist) so the participant knows why they're suddenly
  # registered. Stops as soon as an entry doesn't fit rather than skipping
  # over it, since a later, smaller entry jumping the queue ahead of an
  # earlier, larger one wouldn't be fair — the queue is strictly FIFO.
  #
  # A promoted registration can still be "unpaid" (same as a normal create)
  # if the event/type isn't free — promotion secures the spot, it doesn't
  # collect payment; the participant pays through the existing payment flow
  # after seeing the confirmation.
  class PromoteNext
    def self.call(event)
      new(event).call
    end

    def initialize(event)
      @event = event
    end

    def call
      promoted = []

      @event.waitlist_entries.waiting.order(created_at: :asc).each do |entry|
        break if @event.full?
        next unless fits?(entry)

        registration = promote!(entry)
        promoted << registration if registration
      end

      promoted
    end

    private

    def fits?(entry)
      return false if @event.full?
      requested_types = @event.event_types.where(id: Array(entry.event_type_ids))
      requested_types.none?(&:full?)
    end

    def promote!(entry)
      registration = nil

      ActiveRecord::Base.transaction do
        # Guards a race where the same person ended up registered some other
        # way (e.g. an organizer manually added them) between joining the
        # waitlist and this promotion pass running.
        next if entry.user.registrations.exists?(event_id: @event.id)

        amount = compute_amount(entry.event_type_ids)
        registration = entry.user.registrations.create!(
          event: @event,
          status: "confirmed",
          payment_status: amount.zero? ? "paid" : "unpaid",
          amount_paid_cents: 0
        )

        Array(entry.event_type_ids).each do |type_id|
          registration.registration_event_types.create!(event_type_id: type_id)
        end

        entry.update!(status: "promoted")
      end

      if registration&.wants_notification?(:promoted_from_waitlist)
        RegistrationMailer.promoted_from_waitlist(registration).deliver_later
      end
      registration
    rescue ActiveRecord::RecordInvalid
      # Lost the capacity race between `fits?` and the actual create (e.g.
      # two promotion passes overlapping) — leave the entry "waiting" so the
      # next pass picks it up instead of silently dropping this person.
      nil
    end

    def compute_amount(type_ids)
      ids = Array(type_ids).compact.reject(&:empty?)
      return @event.price_cents if ids.empty? || @event.event_types.empty?

      types = @event.event_types.select { |t| ids.include?(t.id) }
      types.sum(&:effective_price_cents)
    end
  end
end
