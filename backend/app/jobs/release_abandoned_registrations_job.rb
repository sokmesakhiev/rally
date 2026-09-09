# Hourly sweep for capacity held by abandoned checkouts — see
# Registrations::ReleaseAbandoned for what counts as abandoned and why.
#
# Scheduled from config/recurring.yml, which Solid Queue reads in production
# only. The supervisor runs inside Puma (SOLID_QUEUE_IN_PUMA, set by
# infrastructure/ecs.tf), so this needs no separate worker service.
#
# Deliberately silent: nobody is notified. The participant walked away from the
# payment screen, and an email telling them a registration they never completed
# has been cancelled is more confusing than useful. They can simply register
# again — which the partial unique index added alongside this now allows.
class ReleaseAbandonedRegistrationsJob < ApplicationJob
  queue_as :default

  def perform
    result = Registrations::ReleaseAbandoned.call

    # Logged even at zero, so "is this actually running" is answerable from
    # production logs without a database query.
    Rails.logger.info(
      "[release_abandoned] released=#{result.released} promoted_from_waitlist=#{result.promoted}"
    )

    result
  end
end
