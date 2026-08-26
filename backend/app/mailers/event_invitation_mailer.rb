# Sent to a prospective team member's email address — not necessarily a
# Rally user yet, unlike every other mailer in this app, which always
# addresses someone who already has an account. See EventInvitation's class
# comment for why the token itself stays plaintext/time-boxed rather than
# hashed like a password.
class EventInvitationMailer < ApplicationMailer
  # Human-friendly labels for EventMembership::ROLES — nowhere else in the
  # backend needs these today (the frontend owns its own copy for UI), so
  # they live here rather than on the model.
  ROLE_LABELS = {
    "manager" => "Manager",
    "check_in" => "Check-in staff",
    "viewer" => "Viewer"
  }.freeze

  def invite(invitation)
    @invitation = invitation
    @event = invitation.event
    @inviter = invitation.invited_by
    @role_label = ROLE_LABELS.fetch(invitation.role, invitation.role)
    @accept_url = frontend_url("/events/#{@event.id}/invitations/#{invitation.token}")

    mail(to: @invitation.email, subject: "You've been invited to help run #{@event.title}")
  end
end
