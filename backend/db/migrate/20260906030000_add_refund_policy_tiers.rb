class AddRefundPolicyTiers < ActiveRecord::Migration[8.1]
  # The event's refund policy, and the copy taken when someone registers.
  #
  # jsonb rather than a tiers table: a policy is a short, ordered list that is
  # always read and written whole, never queried across events, and — on the
  # registration side — must be frozen at a point in time. That's a document,
  # not a relation. Matches how survey_questions.options already stores its
  # `{id, label}` arrays.
  #
  # Both columns are NULLABLE and default to nothing, on purpose. There are
  # three distinguishable states and collapsing any two of them loses
  # information the UI needs:
  #
  #   nil  — no policy set. Refunds stay a manual organizer decision, which
  #          is exactly how every event behaves today, so this migration
  #          changes no existing behaviour.
  #   []   — an explicit "no refunds at any time" policy the host chose.
  #   [..] — tiers.
  #
  # A default of [] would have silently relabelled every existing event as
  # non-refundable, which is a claim to participants we haven't earned.
  def change
    add_column :events, :refund_policy_tiers, :jsonb

    # The snapshot. Written once at registration and never updated, so a host
    # who tightens their policy afterwards cannot retroactively reduce what
    # someone already agreed to at checkout. See
    # Registration#snapshot_refund_policy.
    add_column :registrations, :refund_policy_tiers, :jsonb
  end
end
