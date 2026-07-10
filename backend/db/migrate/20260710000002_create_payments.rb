class CreatePayments < ActiveRecord::Migration[8.1]
  def change
    create_table :payments, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :registration_id, null: false
      t.string :provider, null: false, default: "aba_payway"
      t.string :tran_id, null: false
      t.string :status, null: false, default: "pending" # pending | approved | declined | cancelled | expired | refunded
      t.integer :amount_cents, null: false
      t.string :currency, null: false, default: "usd"
      t.text :qr_string
      t.text :abapay_deeplink
      t.datetime :expires_at
      t.datetime :paid_at
      t.jsonb :raw_response, default: {}, null: false
      t.timestamps
    end

    add_index :payments, :tran_id, unique: true
    add_index :payments, :registration_id
    add_index :payments, [ :registration_id, :status ]

    add_foreign_key :payments, :registrations
  end
end
