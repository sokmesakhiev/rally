module Api
  module V1
    # Owner-only management of an event's pending invitations — see
    # EventInvitation for the token/lifecycle, EventMembership for what an
    # accepted invitation becomes, and EventAuthorization::CAPABILITIES'
    # :manage_members entry (owner-only, deliberately: letting a Manager add
    # or remove Managers would let the owner get diluted out of their own
    # event with no audit trail they'd notice — see event-membership-tickets.md).
    #
    # Accepting an invitation (issue #276/Ticket E) is a separate, public
    # controller keyed by token, not this one — this controller is entirely
    # about the owner's side of sending/listing/revoking invites.
    class EventInvitationsController < BaseController
      before_action :authenticate_user!
      before_action :set_event

      # GET /api/v1/events/:event_id/invitations — owner-only, pending invites
      def index
        return unless authorize_event!(@event, :manage_members)

        invitations = @event.event_invitations.pending.order(created_at: :desc)
        render json: { invitations: invitations.map { |i| invitation_json(i) } }
      end

      # POST /api/v1/events/:event_id/invitations
      def create
        return unless authorize_event!(@event, :manage_members)

        validate_params_with_schema(EventInvitationCreateRequestSchema) do |validated_params|
          email = validated_params[:email].to_s.downcase.strip
          role = validated_params[:role]

          if email == current_user.email
            render json: { error: "You can't invite yourself.", code: "self_invite" }, status: :unprocessable_entity
            return
          end

          if already_member?(email)
            render json: { error: "This person is already a member of the event.", code: "already_member" },
              status: :unprocessable_entity
            return
          end

          # Must match the DB's partial unique index exactly — that index
          # (see db/migrate/..._create_event_invitations.rb) keys on
          # accepted_at/revoked_at both being NULL, with no expires_at
          # clause, so an expired-but-unrevoked row still occupies the slot
          # even though EventInvitation.pending (which also checks
          # expires_at) no longer considers it pending. Using .pending here
          # instead would let an expired row slip past this check and hit a
          # RecordNotUnique from Postgres instead of a clean 422.
          blocking_invitation = @event.event_invitations
            .where(accepted_at: nil, revoked_at: nil)
            .find_by(email: email)

          if blocking_invitation
            if blocking_invitation.expired?
              # Frees the unique index slot for a fresh invite. An expired
              # invitation shouldn't need an explicit revoke first just to
              # be re-sent — "expired" and "revoked" both mean "not usable
              # anymore" from the recipient's side, so recording it as
              # revoked here is accurate, not a stretch.
              blocking_invitation.revoke!
            else
              render json: { error: "There's already a pending invitation for this email.", code: "invite_pending" },
                status: :unprocessable_entity
              return
            end
          end

          invitation = @event.event_invitations.create!(email: email, role: role, invited_by: current_user)

          EventInvitationMailer.invite(invitation).deliver_later
          EventActivity.log!(
            event: @event, actor: current_user, action: "invite_member",
            metadata: { email: invitation.email, role: invitation.role }
          )

          render json: { invitation: invitation_json(invitation) }, status: :created
        end
      rescue ActiveRecord::RecordInvalid => e
        # EventInvitationCreateRequestSchema only checks shape/role
        # inclusion — email *format* is still just a model validation (see
        # that schema's class comment), so a malformed address can still
        # raise here.
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # DELETE /api/v1/events/:event_id/invitations/:id — owner-only, revokes
      def destroy
        return unless authorize_event!(@event, :manage_members)

        invitation = @event.event_invitations.find(params[:id])
        invitation.revoke!

        EventActivity.log!(
          event: @event, actor: current_user, action: "revoke_invitation",
          metadata: { email: invitation.email, role: invitation.role }
        )

        render json: { message: "Invitation revoked" }
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Invitation not found" }, status: :not_found
      end

      private

      def set_event
        @event = Event.kept.find(params[:event_id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Event not found" }, status: :not_found
      end

      # An invited email is "already a member" only if a real account with
      # that address exists AND holds a membership on this event — a never-
      # seen email plainly can't be, and this deliberately doesn't check
      # EventInvitation rows (a second concern, covered separately by the
      # invite_pending guard below).
      def already_member?(email)
        user = User.find_by(email: email)
        user.present? && @event.event_memberships.exists?(user_id: user.id)
      end

      def invitation_json(invitation)
        {
          id: invitation.id,
          event_id: invitation.event_id,
          email: invitation.email,
          role: invitation.role,
          invited_by_id: invitation.invited_by_id,
          expires_at: invitation.expires_at,
          created_at: invitation.created_at
        }
      end
    end
  end
end
