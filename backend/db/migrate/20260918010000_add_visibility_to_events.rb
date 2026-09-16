# frozen_string_literal: true

# Whether a published event appears in public listings, or is reachable only by
# its URL. See Event::VISIBILITIES.
#
# **Deliberately not called "private".** The value is `unlisted`, because that
# is what it is: the event is hidden from the catalogue and search, and anybody
# holding the link can view it and register. An organizer who reads "Private"
# on the form may reasonably conclude the link is safe to post in a public
# channel, and it isn't — the label would be doing the harm. If access control
# proper is wanted later, that's a third value (`code`, `invite_only`) with a
# real gate behind it, which is why this is a string enum rather than a boolean.
#
# Separate from `is_published`, which answers a different question. Unpublished
# means "not finished / not paid for"; unlisted means "finished, live, and not
# for the catalogue". An unlisted event is fully published: it takes
# registrations, issues certificates and shows results like any other.
class AddVisibilityToEvents < ActiveRecord::Migration[8.1]
  def change
    add_column :events, :visibility, :string, null: false, default: "public"

    # No index. `Event.publicly_visible` already filters on is_published plus
    # three joined suspension checks, and visibility is two-valued — Postgres
    # will not choose an index on it, and adding one would just be write cost
    # on every event update.
    add_check_constraint :events,
                         "visibility IN ('public', 'unlisted')",
                         name: "events_visibility_valid"
  end
end
