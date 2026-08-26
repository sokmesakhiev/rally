# frozen_string_literal: true

# Validates POST /api/v1/events/:event_id/invitations. Shape only (presence,
# role inclusion) — email format is left to EventInvitation's own
# `validates :email, format: { with: URI::MailTo::EMAIL_REGEXP }` (same split
# as ChangeEmailRequestSchema), and the real business-rule checks (self
# invite, already a member, duplicate pending invite) live in
# Api::V1::EventInvitationsController#create since they need DB state this
# schema never sees.
class EventInvitationCreateRequestSchema < ApplicationRequestSchema
  params do
    required(:email).filled(:string)
    required(:role).filled(:string, included_in?: EventMembership::ROLES)
  end
end
