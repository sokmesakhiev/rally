require "rails_helper"

RSpec.describe SendPhoneConfirmationJob do
  it "delegates to Registrations::SendPhoneConfirmation" do
    checkout = Registrations::GuestCheckout.call(email: nil, phone: "012345678", name: "Dara Kim")
    registration = create(:registration, user: checkout.user)

    expect(Registrations::SendPhoneConfirmation).to receive(:call).with(registration)

    described_class.perform_now(registration)
  end
end
