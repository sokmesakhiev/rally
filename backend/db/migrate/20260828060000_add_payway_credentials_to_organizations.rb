class AddPaywayCredentialsToOrganizations < ActiveRecord::Migration[8.1]
  # Registration payments (attendee → organizer) settle into the account of
  # whoever *presents* the event, which is now an Organization rather than the
  # individual who created it — see organization-identity-tickets.md's Ticket
  # B (#331). Without this move, a club's registration money would follow
  # whichever colleague happened to click Create.
  #
  # Column types mirror profiles' exactly: payway_api_key is :text because
  # Active Record encryption stores more than the plaintext length, while
  # merchant_id is a plain :string. Encryption itself is declared on the model
  # (Organization#encrypts), not here.
  def change
    add_column :organizations, :payway_merchant_id, :string
    add_column :organizations, :payway_api_key, :text
    add_column :organizations, :payway_rsa_public_key, :text
  end
end
