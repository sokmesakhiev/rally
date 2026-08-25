class RegistrationMailer < ApplicationMailer
  # new_guest_account: true when this registration was just created via
  # guest checkout (Registrations::GuestCheckout, from
  # Api::V1::RegistrationsController#create) — the recipient has a real
  # Rally account now (a random, never-shown password) but doesn't know
  # that yet, so the template adds a one-line, entirely optional nudge to
  # set a password via the existing forgot-password flow.
  def confirmation(registration, new_guest_account: false)
    @registration = registration
    @event = registration.event
    @user = registration.user
    @event_url = frontend_url("/events/#{@event.id}")
    @owed_cents = registration.owed_amount_cents
    @new_guest_account = new_guest_account
    @forgot_password_url = frontend_url("/forgot-password")

    mail(to: @user.email, subject: "You're registered for #{@event.title}")
  end

  def payment_received(registration)
    @registration = registration
    @event = registration.event
    @user = registration.user
    @payment = registration.latest_payment

    mail(to: @user.email, subject: "Payment received for #{@event.title}")
  end

  # Sent by Refunds::IssueRefund after a refund succeeds (either method —
  # gateway or manual). @full mirrors what actually happened to the
  # registration (Registration#apply_refund!'s `full:` argument): a full
  # refund cancels the registration, so the email should say so plainly
  # rather than implying they're still registered.
  def refund_issued(registration, refund)
    @registration = registration
    @event = registration.event
    @user = registration.user
    @refund = refund
    @full = registration.payment_status == "refunded"

    mail(to: @user.email, subject: "Refund issued for #{@event.title}")
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

  # Sent by NotifyEventDetailsChangedJob, fanned out to every active
  # registration once an organizer edits price/start_at/end_at from
  # EventsController#update. `changes` is a hash keyed by field name
  # (:price_cents, :start_at, :end_at — whichever actually changed), each
  # value a { from:, to: } pair of *already-cast* values (integers for
  # price_cents, Time/ActiveSupport::TimeWithZone for the dates) — see
  # EventsController#notifiable_changes, the sole producer of this shape.
  def details_changed(registration, changes)
    @registration = registration
    @event = registration.event
    @user = registration.user
    @changes = changes
    @event_url = frontend_url("/events/#{@event.id}")

    mail(to: @user.email, subject: "Details changed for #{@event.title}")
  end

  # Exposed to details_changed.html/text.erb — mirrors Payment#formatted_amount's
  # KHR-vs-other-currency branch (see Payment/Refund/EventPlanPayment, each of
  # which duplicates this same logic locally rather than sharing a concern;
  # following that same house convention here since there's no Payment record
  # to format against, just a raw price_cents diff).
  def format_money(cents)
    if @event.currency.to_s.casecmp("khr").zero?
      (cents / 100.0).round.to_s
    else
      format("%.2f", cents / 100.0)
    end
  end
  helper_method :format_money

  def format_time(time)
    time.strftime("%A, %B %-d, %Y at %-I:%M %p")
  end
  helper_method :format_time
end
