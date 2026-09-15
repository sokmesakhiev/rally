class AddRegistrationClosingToEvents < ActiveRecord::Migration[8.1]
  # Lets an organizer stop taking sign-ups before the event is full — for
  # printing bibs, confirming catering, closing a permit headcount. Until now
  # the only ways to stop registrations were to reach capacity or to unpublish,
  # and unpublishing is the wrong tool: it hides the event from everyone,
  # including the people already registered who still need the page for the
  # date, the venue and (later) their results.
  #
  # **Two columns, because they answer different questions**, and collapsing
  # them into one would lose information:
  #
  #   registration_closes_at — a deadline the organizer set in advance. Still
  #     meaningful after it passes ("closed on the 1st, as announced"), and it
  #     is shown to participants *before* it passes so they know to hurry.
  #   registration_closed_at — when someone actually pressed Close. Nil when
  #     open, which is also what reopening resets it to.
  #
  # Registration is shut when *either* applies. A single boolean would have
  # meant a cron job flipping it at the deadline — a scheduled write against
  # every event on the platform, and a window where the deadline has passed
  # but the flag hasn't caught up. Comparing a timestamp needs neither.
  def change
    add_column :events, :registration_closed_at, :datetime
    add_column :events, :registration_closes_at, :datetime

    # Both nullable with no default: NULL means "not closed" / "no deadline",
    # which is the correct state for every event that already exists, so this
    # needs no backfill.

    # The events index page and the organizer dashboard both ask "is this
    # still open" while listing. Partial, because the overwhelming majority of
    # rows are NULL on both and indexing those buys nothing.
    add_index :events, :registration_closes_at,
              where: "registration_closes_at IS NOT NULL",
              name: "index_events_on_registration_closes_at"
  end
end
