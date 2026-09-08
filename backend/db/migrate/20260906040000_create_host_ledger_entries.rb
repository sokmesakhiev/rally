class CreateHostLedgerEntries < ActiveRecord::Migration[8.1]
  # The running account between Rally and a host organization
  # (platform-payments-tickets.md Ticket F).
  #
  # Needed because splitting at capture pays the host before the event, so a
  # refund afterwards is money Rally has already handed over and now has to
  # recover. "How much does this host owe us, or we them" therefore stops
  # being answerable from any single payment and becomes a running total.
  #
  # Append-only by design (see HostLedgerEntry, which refuses updates and
  # destroys). Correcting a mistake means writing a compensating entry, not
  # editing history — otherwise the ledger stops being evidence of anything.
  def change
    create_table :host_ledger_entries, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :organization, null: false, foreign_key: true, type: :uuid, index: false

      # Signed: positive is owed to the host, negative is owed to Rally. One
      # signed column rather than separate debit/credit columns so the
      # balance is a plain SUM that can't disagree with itself.
      t.integer :amount_cents, null: false
      t.string  :currency, null: false, default: "usd"
      t.string  :entry_type, null: false

      # What caused this entry — a PlatformPayment, a Refund, a payout batch.
      # Deliberately a loose polymorphic pair rather than a foreign key per
      # source: the sources live in different tables and more will be added,
      # and a ledger that can't record an entry because its source type isn't
      # modelled yet would be worse than one that stores a type name.
      t.string :source_type
      t.uuid   :source_id

      t.text :description

      # Only created_at. There is no updated_at because there are no updates.
      t.datetime :created_at, null: false
    end

    add_index :host_ledger_entries, [ :organization_id, :created_at ]
    add_index :host_ledger_entries, [ :source_type, :source_id ]

    add_check_constraint :host_ledger_entries,
      "amount_cents <> 0",
      name: "host_ledger_entries_amount_non_zero"
  end
end
