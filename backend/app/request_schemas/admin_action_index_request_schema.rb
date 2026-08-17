# frozen_string_literal: true

# Validates the query string on GET /api/v1/admin/admin_actions — the
# queryable audit trail (see AdminAction, Admin::BaseController#log_admin_action).
class AdminActionIndexRequestSchema < ApplicationRequestSchema
  MAX_PER_PAGE = 100
  DEFAULT_PER_PAGE = 25

  params do
    # Deliberately NOT named `action` — that key collides with Rails' own
    # params[:action] (the controller action name), which routing/dispatch
    # relies on; a query string ?action=... would stomp on it.
    optional(:action_type).maybe(:string)
    optional(:admin_id).maybe(:string)
    optional(:target_type).maybe(:string)
    optional(:page).filled(:integer, gt?: 0)
    optional(:per_page).filled(:integer, gt?: 0, lteq?: MAX_PER_PAGE)
  end
end
