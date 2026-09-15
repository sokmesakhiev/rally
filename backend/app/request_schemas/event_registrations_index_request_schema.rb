# frozen_string_literal: true

# Validates the query string on GET /api/v1/events/:event_id/registrations —
# the organizer's participant list. Pagination plus a name/email search.
#
# Everything is optional, and a bare request returns page 1. That matters
# beyond politeness: this endpoint used to return *every* registration with no
# parameters at all, so anything already calling it keeps working — it just
# gets the first page instead of the whole table.
#
# Same shape and same reasoning as EventIndexRequestSchema, deliberately —
# `page`/`per_page` arrive as strings on the wire and dry-schema's params block
# coerces them, so ?page=abc is a 422 rather than silently becoming page 1 and
# hiding a broken client.
class EventRegistrationsIndexRequestSchema < ApplicationRequestSchema
  # Higher than the public event list's 50: this is one organizer looking at
  # their own event, the rows are cheap, and a check-in desk scrolling a page
  # of 100 is a normal thing to do.
  MAX_PER_PAGE = 100
  DEFAULT_PER_PAGE = 25

  params do
    # Free text over the participant's display name and email — see
    # Registration.search. Blank is allowed and means "no filter", so the
    # frontend can bind it straight to an input without special-casing empty.
    optional(:q).maybe(:string)
    optional(:page).filled(:integer, gt?: 0)
    optional(:per_page).filled(:integer, gt?: 0, lteq?: MAX_PER_PAGE)
  end
end
