# frozen_string_literal: true

# Validates the query string on GET /api/v1/events (public event browsing):
# free-text search, category filter, and pagination.
#
# Everything is optional — a bare GET /api/v1/events must keep working
# unchanged, since that's what the events page requests on first load and what
# any existing client already does.
#
# Note `page`/`per_page` arrive as query-string values, so they're strings on
# the wire; dry-schema's :integer type coerces them (params blocks do coercion,
# unlike plain schemas). An uncoercible value like ?page=abc is a validation
# failure rather than silently becoming 0, which is the behavior we want — it
# surfaces a broken client instead of quietly returning page 1 forever.
class EventIndexRequestSchema < ApplicationRequestSchema
  MAX_PER_PAGE = 50
  DEFAULT_PER_PAGE = 12

  params do
    optional(:q).maybe(:string)
    optional(:category).filled(:string, included_in?: Event::CATEGORIES)
    optional(:page).filled(:integer, gt?: 0)
    # Upper bound is enforced here rather than silently clamped in the
    # controller: ?per_page=100000 is a client bug, and a 422 says so instead
    # of pretending it worked.
    optional(:per_page).filled(:integer, gt?: 0, lteq?: MAX_PER_PAGE)
  end
end
