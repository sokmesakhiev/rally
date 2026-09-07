class AddPaymentModelToEvents < ActiveRecord::Migration[8.1]
  # Which way an attendee's registration money flows for this event:
  #
  #   "direct"   — straight into the organizing organization's own PayWay
  #                merchant account. Rally is never in the payment path.
  #                This is every event that exists today.
  #   "platform" — the participant pays Rally, which splits the capture so
  #                its commission settles to Rally and the remainder to the
  #                host (platform-payments-tickets.md, Ticket C).
  #
  # Defaulting to "direct" is what makes both models coexist without a
  # backfill: every existing event keeps settling exactly as it does now, and
  # nothing in flight changes mid-event.
  def change
    add_column :events, :payment_model, :string, null: false, default: "direct"
  end

  # Deliberately no index — the column has two values, so Postgres would
  # sequential-scan past it anyway. Add one alongside a real query if
  # "all platform events" ever becomes a hot path.
end
