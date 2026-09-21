# frozen_string_literal: true

module Api
  module V1
    module Admin
      # Opening, ending and reviewing staff support sessions. See
      # docs/impersonation-design.md.
      #
      # Every action here takes the admin's **own** token — never an
      # impersonation token. That isn't a special rule: `require_admin!` 404s
      # under an impersonation token (ApplicationController), and three of the
      # four actions are writes, which are refused outright in a support
      # session. So an impersonated session cannot start another, cannot revoke
      # one, and cannot read the history. Ending a session is therefore done
      # with the admin's own credentials, which the frontend still holds — it
      # never overwrote them.
      class ImpersonationsController < BaseController
        # POST /api/v1/admin/impersonations
        def create
          user = User.find(params[:user_id])

          refusal = refusal_for(user)
          return render(json: { error: refusal[:error], code: refusal[:code] },
                        status: :unprocessable_entity) if refusal

          session = nil
          # The session and the notification are created together or not at
          # all. This is the invariant the whole transparency argument rests
          # on: "a session existed that the user was never told about" must not
          # be a state the database can hold. ImpersonationNotifier deliberately
          # doesn't swallow its own failures for the same reason.
          ImpersonationSession.transaction do
            session = ImpersonationSession.start!(
              admin: current_user,
              user: user,
              reason: params[:reason].to_s.strip,
              ip: request.remote_ip,
              user_agent: request.user_agent
            )
            Notifications::ImpersonationNotifier.started(session)
          end

          log_admin_action("impersonate_user", user)

          render json: { impersonation: session_json(session), token: session.token },
                 status: :created
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: e.record.errors.full_messages.join(", ") },
                 status: :unprocessable_entity
        rescue ActiveRecord::RecordNotUnique
          # One-live-session-per-admin is a uniqueness validation *and* a
          # partial unique index, and which one stops a duplicate depends on
          # how the race lands — the validation does its own SELECT, so a
          # double-clicked button can have both requests pass it before either
          # INSERTs. Handling only the validation leaves a 500 that can't be
          # reproduced on demand. Same pairing, and the same fix, as
          # Conversations::Start and the event-report intake.
          render json: { error: "You already have a live impersonation session." },
                 status: :unprocessable_entity
        end

        # DELETE /api/v1/admin/impersonations/current
        #
        # Ending is idempotent: a session that already expired, or that another
        # admin revoked, still returns 200. The caller's intent is "I am done",
        # and answering that with an error would leave the frontend holding a
        # dead token and an error toast it can do nothing about.
        def destroy
          session = ImpersonationSession.find_by(admin: current_user, ended_at: nil, revoked_at: nil)

          if session
            session.end!
            log_admin_action("end_impersonation", session.user)
          end

          render json: { ended: session.present? }
        end

        # GET /api/v1/admin/impersonations
        def index
          sessions = ImpersonationSession.includes(:admin, :user, :revoked_by)
            .newest_first.limit(PAGE_LIMIT)

          render json: {
            impersonations: sessions.map { |s| session_json(s) },
            live_count: ImpersonationSession.live.count
          }
        end

        # POST /api/v1/admin/impersonations/:id/revoke
        #
        # **Any** admin can kill **any** live session, including someone else's.
        # Deliberately not self-only, unlike a support-thread claim: the reason
        # this exists is the laptop left open in a café, and a control only its
        # own holder can pull is not a control.
        def revoke
          session = ImpersonationSession.find(params[:id])

          # Audited only when something was actually revoked. A row saying an
          # admin revoked a session that had already expired describes an act
          # that didn't happen, and an audit log with entries like that in it
          # is one you stop trusting for the entries that matter.
          if session.live?
            session.revoke!(by: current_user)
            log_admin_action("revoke_impersonation", session.user)
          end

          render json: { impersonation: session_json(session.reload) }
        end

        private

        PAGE_LIMIT = 100

        # Returns nil when the session may open. Each refusal is a deliberate
        # decision recorded in the design doc, and each leaves an audit-visible
        # 422 rather than a confusing 404 or a session that mints a token which
        # immediately fails.
        def refusal_for(user)
          if user.id == current_user.id
            # Not an error worth much thought, but a session against yourself
            # would write a notification to yourself and occupy your one live
            # slot. Refuse plainly.
            { error: "You can't impersonate yourself.", code: "impersonation_self" }
          elsif user.admin?
            # The privilege-escalation case. `require_admin!` already 404s under
            # an impersonation token, so this is the second of two mechanisms,
            # not the only one — but refusing here is what makes the *intent*
            # visible, rather than leaving a staff member confused by a 404.
            { error: "Admin accounts can't be impersonated.", code: "impersonation_admin_target" }
          elsif user.suspended? || user.discarded?
            # authenticate_user! refuses both on every request, so a session
            # here would mint a token that 403s instantly and leave an audit row
            # claiming staff entered an account they never entered.
            { error: "This account can't be accessed.", code: "impersonation_unavailable" }
          end
        end

        def session_json(session)
          {
            id: session.id,
            admin: { id: session.admin_id, email: session.admin.email },
            user: { id: session.user_id, email: session.user.email },
            reason: session.reason,
            expires_at: session.expires_at,
            ended_at: session.ended_at,
            revoked_at: session.revoked_at,
            revoked_by: session.revoked_by&.email,
            live: session.live?,
            ip: session.ip,
            created_at: session.created_at
          }
        end
      end
    end
  end
end
