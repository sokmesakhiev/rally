# Organization-facing mailer — see organization-identity-tickets.md's
# Ticket J (#339). Distinct from EventMailer (about one event) and
# UserMailer (about an account).
class OrganizationMailer < ApplicationMailer
  # Sent by Api::V1::Admin::OrganizationsController#suspend right after
  # Organization#suspend! persists.
  #
  # Deliberately unconditional, same reasoning as EventMailer#suspended: this
  # is the platform informing an organizer of a decision about their own
  # organization, not an opt-outable notification. Includes the reason
  # verbatim, plus the organization's name, slug and link, so an appeal has
  # something exact to reference — the same problem the event suspension
  # email solves by including the event link and id.
  #
  # No #unsuspended counterpart: unsuspending is deliberately silent, and the
  # organizer's events reappear on their own (the cascade derives rather than
  # writes, see Event#suspended?).
  def suspended(organization)
    @organization = organization
    @owner = organization.owner
    @reason = organization.suspension_reason
    @organizer_url = frontend_url("/organizers/#{organization.slug}")

    mail(
      to: @owner.email,
      subject: "Your organization \"#{@organization.name}\" has been suspended"
    )
  end
end
