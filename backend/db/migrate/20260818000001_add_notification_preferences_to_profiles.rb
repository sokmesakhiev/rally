class AddNotificationPreferencesToProfiles < ActiveRecord::Migration[8.1]
  # Opt-out, not opt-in — default true so existing accounts keep getting the
  # same emails they already get today until they explicitly turn one off.
  # Only covers RegistrationMailer's non-essential notifications (payment
  # receipts, refund confirmations, waitlist promotions); password resets,
  # email verification, and the initial registration confirmation stay
  # unconditional — see the mailer call sites this gates.
  def change
    add_column :profiles, :notify_payment_received, :boolean, default: true, null: false
    add_column :profiles, :notify_refund_issued, :boolean, default: true, null: false
    add_column :profiles, :notify_promoted_from_waitlist, :boolean, default: true, null: false
  end
end
