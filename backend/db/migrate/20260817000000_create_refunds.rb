class CreateRefunds < ActiveRecord::Migration[8.1]
  def change
    create_table :refunds, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :payment_id, null: false
      t.uuid :initiated_by_id, null: false
      t.integer :amount_cents, null: false
      t.string :refund_method, null: false, default: "gateway" # gateway (ABA PayWay API) | manual (logged, refunded outside the system)
      t.string :status, null: false, default: "pending" # pending | succeeded | failed
      t.text :reason
      t.jsonb :raw_response, default: {}, null: false
      t.datetime :refunded_at
      t.timestamps
    end

    add_index :refunds, :payment_id
    add_index :refunds, :initiated_by_id

    add_foreign_key :refunds, :payments
    add_foreign_key :refunds, :users, column: :initiated_by_id
  end
end
