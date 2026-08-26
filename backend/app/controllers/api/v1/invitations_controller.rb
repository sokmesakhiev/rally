module Api
  module V1
    # The recipient's side of an event invitation, keyed by token — not
    # event_id, since the recipient may not know or care about the event's
    # id, just the link they were emailed. See EventInvitationsController for
    # the owner's side (send/list/revoke), and EventInvitation's class
    # comment for the token/lifecycle this is built on.
    class InvitationsController < BaseController
      before_action :authenticate_user!, only: [ :accept ]
      before_action :set_invitation

      # GET /api/v1/invitations/:token — public, unauthenticated. Deliberately
      # minimal (event title, inviter's display name, role, validity) since
      # anyone holding the link can reach this — not the event's full detail
      # payload. Always 200 for a token that resolves to a real invitation,
      # even an expired/revoked one, so the frontend can render a clear
      # "no longer valid" state from this same response instead of having to
      # branch on an error status for what's really just information.
      def show
        render json: { invitation: landing_json(@invitation) }
      end

      # POST /api/v1/invitations/:token/accept — authenticated. Creates the
      # EventMembership, stamps the invitation accepted, logs member_joined.
      def accept
        if @invitation.revoked? || (@invitation.expired? && !@invitation.accepted?)
          render_invalid
          return
        end

        # Strict email match: the signed-in account must be the one the
        # invitation was addressed to. The looser alternative (any signed-in
        # user holding the token may accept) would make forwarded invites
        # work, but turns the token into a bearer credential — the exact
        # property shareable join links were rejected for when this feature
        # was scoped (see event-membership-tickets.md).
        if @invitation.email != current_user.email
          render json: {
            error: "Sign in as #{@invitation.email} to accept this invitation.",
            code: "invitation_email_mismatch"
          }, status: :unprocessable_entity
          return
        end

        membership = EventMembership.find_or_initialize_by(event: @invitation.event, user: current_user)
        newly_created = membership.new_record?

        if newly_created
          membership.role = @invitation.role
          membership.invited_by = @invitation.invited_by
          membership.accepted_at = Time.current
          membership.save!
        end

        # Idempotent: a duplicate accept (double click, retried request)
        # lands here with newly_created false and accepted_at already set —
        # both no-ops below — rather than erroring or creating a second row.
        @invitation.accept! unless @invitation.accepted?

        if newly_created
          EventActivity.log!(
            event: @invitation.event, actor: current_user, action: "member_joined",
            metadata: { role: membership.role }
          )
        end

        render json: { membership: membership_json(membership) }
      rescue ActiveRecord::RecordInvalid => e
        render json: { error: e.message }, status: :unprocessable_entity
      rescue ActiveRecord::RecordNotUnique
        # Lost a genuine concurrent-request race at the DB level (the
        # [event_id, user_id] unique index from Ticket A) rather than at the
        # validation layer above — the membership it collided with is what
        # we want anyway, so this is still a success, not a 500.
        membership = EventMembership.find_by(event: @invitation.event, user: current_user)
        render json: { membership: membership_json(membership) }
      end

      private

      def set_invitation
        @invitation = EventInvitation.find_by(token: params[:token])
        return if @invitation

        render json: { error: "Invitation not found" }, status: :not_found
      end

      def render_invalid
        render json: { error: "This invitation is no longer valid.", code: "invitation_invalid" },
          status: :unprocessable_entity
      end

      def invitation_status(invitation)
        return "accepted" if invitation.accepted?
        return "revoked" if invitation.revoked?
        return "expired" if invitation.expired?
        "pending"
      end

      def landing_json(invitation)
        event = invitation.event
        {
          event_id: event.id,
          event_title: event.title,
          inviter_name: invitation.invited_by.profile&.display_name.presence || invitation.invited_by.email,
          role: invitation.role,
          email: invitation.email,
          valid: invitation.pending?,
          status: invitation_status(invitation)
        }
      end

      def membership_json(membership)
        {
          id: membership.id,
          event_id: membership.event_id,
          role: membership.role,
          accepted_at: membership.accepted_at
        }
      end
    end
  end
end
