module Api
  module V1
    module Admin
      # Shared base for the Rally staff moderation surface.
      #
      # Two guards, in order: authenticate_user! (a valid, non-suspended
      # account) then require_admin! (that account has `admin` set). Both live
      # in ApplicationController; require_admin! renders 404 rather than 403 so
      # this surface doesn't advertise itself to non-admins.
      #
      # Staff access is granted from the console
      # (`user.update!(staff_role: "support")`) — there
      # is deliberately no endpoint for promoting a user, so a compromised
      # admin session can't mint more admins.
      #
      # Inherits from Api::V1::BaseController (not ApplicationController
      # directly) so it picks up the ValidateParams concern — Admin::Users and
      # Admin::Events controllers validate their index/suspend params via
      # validate_params_with_schema, which only BaseController provides.
      class BaseController < Api::V1::BaseController
        before_action :authenticate_user!
        before_action :authorize_staff_action!

        private

        # Looks the capability up from the controller's own declaration.
        #
        # **`fetch`, so an action without a declared capability raises rather
        # than inheriting whatever the last one had.** That is the whole
        # safety property of D3, and it is not a new idea here —
        # EventsController#authorize_creator! has worked this way since
        # role-gating landed, precisely because the alternative failure is
        # silent. spec/requests/admin_capability_coverage_spec.rb turns the
        # raise into a suite failure rather than a 500 somebody meets in
        # production.
        def authorize_staff_action!
          require_staff!(self.class::ACTION_CAPABILITIES.fetch(action_name))
        end

        # Every state-changing admin action goes through here, so there's a
        # queryable audit trail of who did what — see AdminAction.log!, which
        # this and Api::V1::RefundsController#create (the one admin-reachable
        # action outside this namespace) both call. Deliberately logs actor
        # and target ids, not emails.
        def log_admin_action(action, target)
          AdminAction.log!(admin: current_user, action: action, target: target)
        end
      end
    end
  end
end
