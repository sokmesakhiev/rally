require "rails_helper"

RSpec.describe Registrations::SendPhoneConfirmation do
  describe ".call" do
    it "delivers a message with the event title and a link to the event page via Sms::Client" do
      checkout = Registrations::GuestCheckout.call(email: nil, phone: "012345678", name: "Dara Kim")
      event = create(:event, title: "Angkor 10K")
      registration = create(:registration, event: event, user: checkout.user)

      expect(Sms::Client).to receive(:deliver) do |to:, body:|
        expect(to).to eq("012345678")
        expect(body).to include("Angkor 10K")
        expect(body).to include("/events/#{event.id}")
        Sms::Client::Result.new(success: true, provider: "null", error: nil)
      end

      described_class.call(registration)
    end

    it "does nothing when the registrant somehow has no phone on file" do
      user = create(:user) # normal factory user — no phone set on the profile
      registration = create(:registration, user: user)

      expect(Sms::Client).not_to receive(:deliver)

      described_class.call(registration)
    end
  end
end
