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
end
