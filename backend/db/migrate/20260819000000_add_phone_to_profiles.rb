class AddPhoneToProfiles < ActiveRecord::Migration[8.1]
  def change
    # Lives on Profile, not User — phone is contact/display info like
    # display_name/avatar_url (freely editable via ProfilesController, no
    # current-password gate), not a login credential like email/password.
    # Still unique (nulls allowed) so Registrations::GuestCheckout can treat
    # it as an identity-matching field the same way it already does for
    # email — see that service's class comment for why a match returns a
    # conflict rather than silently attaching to the existing account.
    add_column :profiles, :phone, :string
    add_index :profiles, :phone, unique: true, where: "phone IS NOT NULL"
  end
end
