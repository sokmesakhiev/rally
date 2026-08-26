module Api
  module V1
    # Managing an event's *accepted* team — see EventInvitationsController
    # for sending/listing/revoking pending invites (the state before this),
    # and EventMembership for the model this reads and writes.
    class EventMembersController < BaseController
      before_action :authenticate_user!
      before_action :set_event, only: [ :update, :destroy ]

      # GET /api/v1/events/:event_id/members — visible to any member
      # (:view_event is granted to every role, see
      # EventAuthorization::CAPABILITIES), not just the owner: you should be
      # able to see who else is on the team you're on. 404-style (not
      # authorize_event!) since a stranger has no relationship with this
      # event at all — same reasoning as every other list-style endpoint
      # gated this way (registrations#event_registrations, survey_responses,
      # events#activity).
      def index
        event = find_authorized_event!(
          params[:event_id], :view_event,
          scope: Event.kept.includes(:creator, event_memberships: { user: :profile })
        )

        render json: { members: members_json(event) }
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Event not found" }, status: :not_found
      end

      # PATCH /api/v1/events/:event_id/members/:id — owner-only, changes role
      def update
        return unless authorize_event!(@event, :manage_members)

        membership = @event.event_memberships.find(params[:id])

        validate_params_with_schema(EventMembershipUpdateRequestSchema) do |validated_params|
          previous_role = membership.role
          new_role = validated_params[:membership][:role]

          if membership.update(role: new_role)
            if previous_role != new_role
              EventActivity.log!(
                event: @event, actor: current_user, action: "change_member_role",
                metadata: {
                  user_id: membership.user_id,
                  member_name: membership.user.profile&.display_name,
                  member_email: membership.user.email,
                  from: previous_role, to: new_role
                }
              )
            end

            render json: { member: member_json(membership) }
          else
            render json: { error: membership.errors.full_messages.join(", ") }, status: :unprocessable_entity
          end
        end
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Member not found" }, status: :not_found
      end

      # DELETE /api/v1/events/:event_id/members/:id — owner removes a
      # member, OR a member removes *themselves* (leaves the event).
      # Deliberately not authorize_event!(:manage_members) unconditionally —
      # that would let the owner remove people but give a member no way to
      # leave except asking the owner to do it for them.
      def destroy
        membership = @event.event_memberships.find(params[:id])
        self_removal = membership.user_id == current_user.id

        return unless self_removal || authorize_event!(@event, :manage_members)

        removed_user_id = membership.user_id
        removed_user_name = membership.user.profile&.display_name
        removed_user_email = membership.user.email

        membership.destroy!

        EventActivity.log!(
          event: @event, actor: current_user, action: "remove_member",

          metadata: {
            user_id: removed_user_id,
            member_name: removed_user_name,
            member_email: removed_user_email,
            self_removal: self_removal
          }
        )

        render json: { message: self_removal ? "You have left the event" : "Member removed" }
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Member not found" }, status: :not_found
      end

      private

      def set_event
        @event = Event.kept.find(params[:event_id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Event not found" }, status: :not_found
      end

      # The owner is deliberately not an EventMembership row (see that
      # model's class comment) — synthesized here as the list's first entry
      # so the frontend never has to special-case an absent owner slot.
      # `id: nil` marks it as not a real membership row (nothing to PATCH/
      # DELETE against); joined_at falls back to the event's own created_at,
      # since creating the event *is* how the owner joined it.
      def members_json(event)
        owner = event.creator
        owner_entry = {
          id: nil,
          user_id: owner.id,
          role: "owner",
          display_name: owner.profile&.display_name,
          avatar_url: owner.profile&.avatar_url,
          joined_at: event.created_at
        }

        [ owner_entry ] + event.event_memberships.map { |m| member_json(m) }
      end

      def member_json(membership)
        {
          id: membership.id,
          user_id: membership.user_id,
          role: membership.role,
          display_name: membership.user.profile&.display_name,
          avatar_url: membership.user.profile&.avatar_url,
          joined_at: membership.accepted_at
        }
      end
    end
  end
end
