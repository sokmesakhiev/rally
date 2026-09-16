class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class

  # Drops keys whose value is nil *and* whose column is NOT NULL with a
  # database default, so an explicit `null` from a client means "use the
  # default" rather than "write NULL".
  #
  # ── Why this is needed at all ───────────────────────────────────────────────
  # Request schemas correctly declare optional fields as `.maybe`, which permits
  # nil. For a nullable column that's the whole story. For a NOT NULL column
  # with a default it is a **500**: the insert raises
  # ActiveRecord::NotNullViolation, which is a StatementInvalid — *not* a
  # RecordInvalid — so the `rescue ActiveRecord::RecordInvalid` that controllers
  # wrap their saves in doesn't catch it, and the caller gets a 500 for an
  # ordinary request.
  #
  # Sending null for an optional field is normal client behaviour: it's what a
  # form does for a cleared input and what a JSON client does instead of
  # omitting a key. So the fix is to honour the intent rather than reject it —
  # an omitted key and an explicit null now do the same thing.
  #
  # Known reachable today: events.brand_color / currency / price_cents,
  # registrations.amount_paid_cents, surveys.title.
  #
  # **This deliberately does not touch NOT NULL columns without a default.** A
  # null `title` still reaches the model and fails validation with a 422, which
  # is the right answer — the caller asked for something impossible, rather than
  # asking for the default.
  def self.reject_nils_for_defaulted_columns(attrs)
    attrs.reject { |key, value| value.nil? && defaulted_not_null_columns.include?(key.to_s) }
  end

  # Derived from `columns_hash` rather than a hand-written list per model: a
  # list would be wrong the first time someone adds a NOT NULL column with a
  # default and doesn't think about this method. `columns_hash` is memoised per
  # process, so this costs nothing per request.
  #
  # A plain frozen Array, not a Set — these are a handful of strings per table,
  # where `include?` beats hashing and needs no `require "set"`.
  def self.defaulted_not_null_columns
    @defaulted_not_null_columns ||=
      columns_hash.filter_map { |name, column| name unless column.null || column.default.nil? }.freeze
  end
end
