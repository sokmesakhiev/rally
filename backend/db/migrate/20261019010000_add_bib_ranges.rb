# frozen_string_literal: true

# Bib number ranges, for automatic assignment.
#
# The same three columns on both tables, and the duplication is deliberate
# rather than lazy. A registration is numbered from **its event type's** range;
# an event with no types at all has nowhere else to put a range, so the event
# carries one for exactly that case. The two never compete — which applies is
# decided by whether the registration has a type, not by a precedence rule, so
# there is no "which one won?" to debug when a number comes out wrong.
#
# `bib_start` is nullable with **no default**, and that is the feature's only
# piece of configuration ceremony. A default of 1 would make every event in the
# platform look configured, so an organizer who meant 1000–1999 and forgot to
# say so would get 1–143 with nothing to tell them it had happened. Nil means
# "not set up", the preview names the groups in that state, and nothing is
# assigned for them.
class AddBibRanges < ActiveRecord::Migration[8.1]
  def change
    # Printed on the bib itself, so it is part of the identifier rather than
    # decoration: "10K-1042" is the number, not "1042 in the 10K".
    add_column :event_types, :bib_prefix, :string
    add_column :event_types, :bib_start, :integer
    # Zero-padding width, counted on the digits only — padding 4 with start 7
    # gives "0007". Real bibs are printed with their leading zeros and
    # `registrations.bib_number` is a string precisely so they survive.
    #
    # **Nullable with no default**, which looks like the wrong call for a
    # numeric setting and isn't. `NOT NULL DEFAULT 0` would make an explicit
    # `null` from the client a NotNullViolation — a StatementInvalid, not a
    # RecordInvalid, so a 500 rather than a 422. The house fix for that is
    # `ApplicationRecord.reject_nils_for_defaulted_columns`, but it rejects
    # over *top-level* attributes only and these arrive nested inside
    # `event_types_attributes`, where nothing strips them. Nil simply means
    # no padding; `to_i` already reads it that way.
    add_column :event_types, :bib_padding, :integer

    add_column :events, :bib_prefix, :string
    add_column :events, :bib_start, :integer
    add_column :events, :bib_padding, :integer
  end
end
