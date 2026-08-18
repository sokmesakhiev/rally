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
      # Admin is granted from the console (`user.update!(admin: true)`) — there
      # is deliberately no endpoint for promoting a user, so a compromised
      # admin session can't mint more admins.
      #
      # Inherits from Api::V1::BaseController (not ApplicationController
      # directly) so it picks up the ValidateParams concern — Admin::Users and
      # Admin::Events controllers validate their index/suspend params via
      # validate_params_with_schema, which only BaseController provides.
      class BaseController < Api::V1::BaseController
        before_action :authenticate_user!
        before_action :require_admin!

        private

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
