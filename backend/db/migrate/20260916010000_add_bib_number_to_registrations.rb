# frozen_string_literal: true

# Bib numbers. Added for the Partner API (docs/partner-api-design.md, D10) but
# the gap is older than that: a timing system's entire data model is keyed on
# bib, and until now the only way to match a finisher to a registration was
# email (see Results::ImportCsv), which no chip-timing export contains.
#
# A string, not an integer, because real bibs are not integers — "A1042",
# "10K-233", "0007" (where the leading zeros are printed on the bib and an
# integer column would eat them). Nothing sorts or sums this column.
#
# The unique index is partial and scoped to the event, matching the shape
# already used for registrations(event_id, user_id): unassigned bibs are NULL
# and Postgres allows many NULLs under a unique index, while two runners in
# one race cannot share a number. It is deliberately NOT scoped to kept rows
# the way the user_id index is — a withdrawn runner's bib should not be
# silently reissued to someone else while their result and certificate history
# still reference it. Freeing a number is an explicit edit.
class AddBibNumberToRegistrations < ActiveRecord::Migration[8.1]
  def change
    add_column :registrations, :bib_number, :string

    add_index :registrations,
              [ :event_id, :bib_number ],
              unique: true,
              where: "bib_number IS NOT NULL",
              name: "index_registrations_on_event_id_and_bib_number"
  end
end
