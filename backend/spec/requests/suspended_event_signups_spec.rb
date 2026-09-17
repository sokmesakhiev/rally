require "rails_helper"

# Suspending an event must stop participants signing up for it.
#
# It didn't. `Event#suspend!` forces is_published false and freezes the
# *organizer* out via EventAuthorization::SUSPENDED_ALLOWED_CAPABILITIES — but
# neither Registration nor WaitlistEntry looked at `suspended_at`, and neither
# RegistrationsController#set_event (`Event.kept.find`) nor the waitlist's
# equivalent checks published-ness. So anyone holding the event id could still
# register for an event an admin had taken down, and pay for it.
RSpec.describe "Sign-ups on a suspended event", type: :request do
  let(:participant) { create(:user) }
  let(:event) { create(:event, capacity: 10) }

  describe "registration" do
    it "is refused" do
      event.suspend!(reason: "under review")

      post "/api/v1/events/#{event.id}/registrations", headers: auth_headers(participant)

      expect(response).to have_http_status(:unprocessable_content)
      expect(json["code"]).to eq("event_suspended")
    end

    it "creates no registration" do
      event.suspend!(reason: "under review")

      expect {
        post "/api/v1/events/#{event.id}/registrations", headers: auth_headers(participant)
      }.not_to change(Registration, :count)
    end

    it "works again once the suspension is lifted" do
      event.suspend!(reason: "under review")
      event.unsuspend!

      post "/api/v1/events/#{event.id}/registrations", headers: auth_headers(participant)

      expect(response).to have_http_status(:created)
    end
  end

  describe "the waitlist" do
    it "is refused too" do
      event.update!(capacity: 1)
      create(:registration, event: event)
      event.suspend!(reason: "under review")

      post "/api/v1/events/#{event.id}/waitlist_entries", headers: auth_headers(participant)

      expect(response).to have_http_status(:unprocessable_content)
      expect(json["code"]).to eq("event_suspended")
    end
  end

  # An event can be several things at once and only the first code is reported.
  # Suspended outranks the rest because the organizer cannot undo it — telling
  # a participant "registration is closed" would send them to ask the organizer
  # to reopen something the organizer has no control over.
  describe "which reason wins" do
    it "reports suspended rather than closed" do
      event.close_registration!
      event.suspend!(reason: "under review")

      post "/api/v1/events/#{event.id}/registrations", headers: auth_headers(participant)

      expect(json["code"]).to eq("event_suspended")
    end

    it "reports suspended rather than full" do
      event.update!(capacity: 1)
      create(:registration, event: event)
      event.suspend!(reason: "under review")

      post "/api/v1/events/#{event.id}/registrations", headers: auth_headers(participant)

      expect(json["code"]).to eq("event_suspended")
    end
  end

  # Same `on: :create` reasoning as registration_closed: a registration's row is
  # written before its KHQR payment settles, so a suspension landing mid-payment
  # must not make the ABA webhook fail when it marks them paid — which would
  # take the money and refuse the spot.
  it "does not reach backwards into a registration already in flight" do
    registration = create(:registration, event: event, payment_status: "unpaid")
    event.suspend!(reason: "under review")

    expect { registration.update!(payment_status: "paid") }.not_to raise_error
  end
end
