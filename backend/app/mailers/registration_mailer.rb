class RegistrationMailer < ApplicationMailer
  def confirmation(registration)
    @registration = registration
    @event = registration.event
    @user = registration.user
    @event_url = frontend_url("/events/#{@event.id}")
    @owed_cents = registration.owed_amount_cents

    mail(to: @user.email, subject: "You're registered for #{@event.title}")
  end

  def payment_received(registration)
    @registration = registration
    @event = registration.event
    @user = registration.user
    @payment = registration.latest_payment

    mail(to: @user.email, subject: "Payment received for #{@event.title}")
  end

  # Sent by Waitlists::PromoteNext when a waitlisted participant is
  # auto-promoted into a real registration after a spot opened up.
  # Deliberately its own template rather than reusing #confirmation — the
  # framing ("a spot opened up") is different even though the underlying
  # registration record looks identical to one created normally.
  def promoted_from_waitlist(registration)
    @registration = registration
    @event = registration.event
    @user = registration.user
    @event_url = frontend_url("/events/#{@event.id}")
    @owed_cents = registration.owed_amount_cents

    mail(to: @user.email, subject: "A spot opened up for #{@event.title}!")
  end
end
