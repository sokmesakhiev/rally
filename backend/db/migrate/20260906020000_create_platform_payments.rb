class CreatePlatformPayments < ActiveRecord::Migration[8.1]
  # A participant paying *Rally*, which splits the capture between its own
  # commission and the host's share.
  #
  # A separate table from `payments` rather than columns bolted onto it, per
  # platform-payments-tickets.md Ticket C: `payments` records "attendee paid
  # the organizer" and this records "attendee paid Rally, Rally split it".
  # Sharing one table would mean every query about money forever has to first
  # establish which kind of money it is.
  def change
    create_table :platform_payments, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      # index: false because the composite [registration_id, status] below
      # already covers registration_id as its leftmost prefix, including for
      # the foreign key. (`payments` carries both a single-column and a
      # composite index for historical reasons — not a pattern to copy.)
      t.references :registration, null: false, foreign_key: true, type: :uuid, index: false

      t.string :provider, null: false, default: "aba_payway"
      t.string :currency, null: false, default: "usd"
      t.string :status,   null: false, default: "pending"

      # The split. Integer cents throughout, like the rest of the app —
      # note PayWay's payout API reports amounts as decimal floats, so
      # whatever writes these is a conversion boundary that needs to round
      # deliberately rather than by accident.
      t.integer :gross_amount_cents,    null: false
      t.integer :platform_fee_cents,    null: false
      t.integer :host_net_cents,        null: false
      t.integer :refunded_amount_cents, null: false, default: 0

      # Gateway identifiers. tran_id is ours (sent to PayWay); the other two
      # come back from ABA and their exact contents are still unconfirmed —
      # the sandbox spike hasn't been run. See docs/PAYWAY-PREAUTH-SPIKE.md §6.
      t.string :tran_id, null: false
      t.string :capture_reference
      t.string :payout_reference

      # Two genuinely different expiries, which is why neither is just
      # `expires_at`:
      #   expires_at      — the QR code's own short lifetime (~15 min), the
      #                     same thing `payments.expires_at` means.
      #   hold_expires_at — when ABA auto-cancels an uncaptured pre-auth and
      #                     returns the money to the payer (30 days).
      t.datetime :expires_at
      t.datetime :hold_expires_at
      t.datetime :authorized_at
      t.datetime :captured_at

      t.jsonb :raw_response, null: false, default: {}

      t.timestamps
    end

    add_index :platform_payments, :tran_id, unique: true
    add_index :platform_payments, [ :registration_id, :status ]

    # The invariant is also a model validation, but it belongs here too:
    # update_column, update_all and insert_all all skip validations, and a
    # split that doesn't add up is the one corruption in this table that
    # would be both silent and unrecoverable after the fact.
    add_check_constraint :platform_payments,
      "gross_amount_cents = platform_fee_cents + host_net_cents",
      name: "platform_payments_split_sums_to_gross"

    add_check_constraint :platform_payments,
      "gross_amount_cents > 0 AND platform_fee_cents >= 0 AND host_net_cents >= 0",
      name: "platform_payments_amounts_non_negative"

    add_check_constraint :platform_payments,
      "refunded_amount_cents >= 0 AND refunded_amount_cents <= gross_amount_cents",
      name: "platform_payments_refund_within_gross"
  end
end
