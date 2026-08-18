class AddPaywayRsaPublicKeyToProfiles < ActiveRecord::Migration[8.1]
  def change
    # Only needed for AbaPayway::Client#refund (see that file) — generate_qr
    # and check_transaction don't use it, so this is intentionally separate
    # from payway_configured?'s merchant_id/api_key pair rather than folding
    # into it; an organizer can take payments without ever setting this, and
    # only loses the ability to issue gateway refunds (the manual/logged
    # refund path still works) until they add it. Not encrypted like
    # payway_api_key — an RSA *public* key isn't a secret (it's meant to
    # encrypt data ABA can read, not the other way around), so plaintext
    # storage is fine here.
    add_column :profiles, :payway_rsa_public_key, :text
  end
end
