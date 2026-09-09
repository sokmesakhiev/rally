# Enqueued by Api::V1::EventsController#update (see #notifiable_changes)
# whenever an organizer edits price_cents/start_at/end_at on a published
# event. Fans a single RegistrationMailer#details_changed out to every
# currently-active registrant — deliberately not to cancelled/discarded
# registrations, which no longer hold a spot and have nothing to review.
#
# `event` and `changes` are passed as plain arguments (not re-fetched here)
# the same way ProcessAbaPaywayWebhookJob takes its payable directly —
# ActiveJob serializes the Event AR object via GlobalID, and `changes`'
# Time values serialize/deserialize natively through ActiveJob (unlike a
# jsonb column, which would stringify them).
class NotifyEventDetailsChangedJob < ApplicationJob
  queue_as :default

  def perform(event, changes)
    return if changes.blank?

    event.registrations.kept.active.includes(:user).find_each do |registration|
      Notifications::RegistrationNotifier.event_details_changed(registration)

      next unless registration.wants_notification?(:event_details_changed)

      RegistrationMailer.details_changed(registration, changes).deliver_later
    end
  end
end
