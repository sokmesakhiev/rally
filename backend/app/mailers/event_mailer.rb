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
end
