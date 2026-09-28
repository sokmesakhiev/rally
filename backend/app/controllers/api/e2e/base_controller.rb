module Api
  module E2e
    # Second of the three guards described in docs/e2e-testing-design.md D4.
    #
    # config/routes.rb already refuses to draw anything under this namespace
    # outside the `e2e` environment, so in principle this class can only ever
    # run there. This check exists for the case where that stops being true:
    # a refactor that lifts the route block out of its `if`, a
    # copy-and-pasted `namespace :e2e` somewhere else, an engine mounting the
    # controller directly. Any of those would arm a database-truncating
    # endpoint silently, which is the one failure mode worth paying for twice.
    #
    # Deliberately **not** `Api::V1::BaseController`. These endpoints are not
    # part of the versioned public API, take no JWT, and must not inherit an
    # authentication story that could later be relaxed — nor appear in the
    # same file tree as endpoints real clients call.
    class BaseController < ActionController::API
      before_action :ensure_e2e_environment!

      private

      def ensure_e2e_environment!
        return if Rails.env.e2e?

        Rails.logger.error(
          "[e2e] #{self.class.name}##{action_name} was reached in the " \
          "#{Rails.env} environment. This controller truncates the database. " \
          "The route guard in config/routes.rb has been bypassed — find out how."
        )
        head :not_found
      end
    end
  end
end
