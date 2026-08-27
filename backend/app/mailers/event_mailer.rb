# Organizer-facing mailer — distinct from RegistrationMailer, which is
# always addressed to a participant. Currently just the one notification;
# split into its own class rather than piling onto RegistrationMailer so
# "who is this email even for" stays obvious from the class name alone.
class EventMailer < ApplicationMailer
  # Sent once, right after Api::V1::EventsController#create persists the
  # event. Deliberately unconditional (no notify_* opt-out gate) — this is
  # the organizer confirming their own just-taken action succeeded, the same
  # category as RegistrationMailer#confirmation for a participant, not a
  # secondary notification about something someone else did.
  def created(event)
    @event = event
    @creator = event.creator
    @manage_url = frontend_url("/dashboard/events/#{@event.id}")

    mail(to: @creator.email, subject: "Your event \"#{@event.title}\" has been created")
  end

  # Sent by Api::V1::Admin::EventsController#suspend right after
  # Event#suspend! persists — see event-freeze-and-terms-tickets.md's Ticket C.
  # Deliberately unconditional, same reasoning as #created: this is the
  # platform informing the owner of a decision about their own event, not a
  # secondary/opt-outable notice (no notify_* gate). Includes
  # @event.suspension_reason verbatim, per the up-front scoping decision that
  # a suspension always carries a reason and that reason is shared with the
  # owner. Unlike #created, there's no #unsuspended counterpart yet — see the
  # doc's "Open questions".
  def suspended(event)
    @event = event
    @creator = event.creator
    @reason = event.suspension_reason
    # Included so an appeal email has something exact to search on — the
    # title alone isn't a reliable lookup key (can repeat or get edited), and
    # this link still loads read-only for the owner while suspended (see
    # EventAuthorization::SUSPENDED_ALLOWED_CAPABILITIES's view_event entry).
    @manage_url = frontend_url("/dashboard/events/#{@event.id}")

    mail(to: @creator.email, subject: "Your event \"#{@event.title}\" has been suspended")
  end
end
