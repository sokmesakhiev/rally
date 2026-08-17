class AddRefundedAmountCentsToPayments < ActiveRecord::Migration[8.1]
  def change
    # Running total of everything successfully refunded against this payment
    # (across possibly multiple partial Refund rows) — cached here the same
    # way Registration#amount_paid_cents caches its own running total,
    # rather than always summing Refund.succeeded on the fly.
    add_column :payments, :refunded_amount_cents, :integer, null: false, default: 0
  end
end
