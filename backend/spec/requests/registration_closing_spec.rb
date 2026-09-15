require "rails_helper"

RSpec.describe "Registration closing", type: :request do
  let(:organizer) { create(:user) }
  let(:event) { create(:event, creator: organizer, capacity: 100) }
  let(:headers) { auth_headers(organizer) }

  describe "POST /api/v1/events/:id/close_registration" do
    it "closes registration and reports it on the event payload" do
      post "/api/v1/events/#{event.id}/close_registration", headers: headers

      expect(response).to have_http_status(:ok)
      expect(json["event"]["registration_closed"]).to be true
      expect(json["event"]["registration_closed_at"]).to be_present
      expect(event.reload).to be_registration_closed
    end

    # Two managers pressing the button is a normal thing to happen; the second
    # press shouldn't error, and shouldn't move the recorded time either.
    it "is idempotent and doesn't overwrite the original closing time" do
      post "/api/v1/events/#{event.id}/close_registration", headers: headers
      first = event.reload.registration_closed_at

      travel_to(1.hour.from_now) do
        post "/api/v1/events/#{event.id}/close_registration", headers: headers
      end

      expect(response).to have_http_status(:ok)
      expect(event.reload.registration_closed_at).to be_within(1.second).of(first)
    end

    # Closing is an edit to the event, so it sits with :update_event
    # (owner + manager) rather than the owner-only :unpublish_event.
    it "is refused for someone who can't manage the event" do
      post "/api/v1/events/#{event.id}/close_registration", headers: auth_headers(create(:user))

      expect(response).to have_http_status(:forbidden).or have_http_status(:not_found)
      expect(event.reload).not_to be_registration_closed
    end

    # The distinction that motivates the whole feature: closing must not hide
    # the event from the people already registered.
    it "leaves the event published and publicly visible" do
      post "/api/v1/events/#{event.id}/close_registration", headers: headers

      expect(event.reload.is_published).to be true

      get "/api/v1/events/#{event.id}"
      expect(response).to have_http_status(:ok)
      expect(json["event"]["registration_closed"]).to be true
    end
  end

  describe "POST /api/v1/events/:id/reopen_registration" do
    it "reopens and clears a passed deadline so it can't immediately re-close" do
      event.update!(registration_closes_at: 1.day.ago)
      event.close_registration!

      post "/api/v1/events/#{event.id}/reopen_registration", headers: headers

      expect(json["event"]["registration_closed"]).to be false
      expect(event.reload.registration_closes_at).to be_nil
    end
  end

  describe "PATCH /api/v1/events/:id with registration_closes_at" do
    it "accepts a deadline" do
      deadline = 3.days.from_now

      patch "/api/v1/events/#{event.id}",
            params: { event: { registration_closes_at: deadline.iso8601 } }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(event.reload.registration_closes_at).to be_within(1.second).of(deadline)
    end

    it "clears the deadline when sent null" do
      event.update!(registration_closes_at: 3.days.from_now)

      patch "/api/v1/events/#{event.id}",
            params: { event: { registration_closes_at: nil } }, headers: headers

      expect(event.reload.registration_closes_at).to be_nil
    end

    # Kept out of the update schema on purpose, so "when was this closed"
    # can't be back-dated by anyone editing the event form.
    it "ignores an attempt to set registration_closed_at directly" do
      patch "/api/v1/events/#{event.id}",
            params: { event: { registration_closed_at: 1.year.ago.iso8601 } }, headers: headers

      expect(event.reload.registration_closed_at).to be_nil
    end
  end

  describe "signing up for a closed event" do
    let(:participant) { create(:user) }

    it "refuses a registration with code registration_closed, not full" do
      event.close_registration!

      post "/api/v1/events/#{event.id}/registrations", headers: auth_headers(participant)

      expect(response).to have_http_status(:unprocessable_content)
      expect(json["code"]).to eq("registration_closed")
    end

    it "refuses a waitlist entry too" do
      event.update!(capacity: 1)
      create(:registration, event: event)
      event.close_registration!

      post "/api/v1/events/#{event.id}/waitlist_entries", headers: auth_headers(participant)

      expect(response).to have_http_status(:unprocessable_content)
      expect(json["code"]).to eq("registration_closed")
    end

    # A closed event can also be full. "The organizer closed this" is the more
    # accurate thing to say, and unlike "full" it offers no waitlist.
    it "reports closed rather than full when both are true" do
      event.update!(capacity: 1)
      create(:registration, event: event)
      event.close_registration!

      post "/api/v1/events/#{event.id}/registrations", headers: auth_headers(participant)

      expect(json["code"]).to eq("registration_closed")
    end

    it "still accepts registrations once reopened" do
      event.close_registration!
      event.reopen_registration!

      post "/api/v1/events/#{event.id}/registrations", headers: auth_headers(participant)

      expect(response).to have_http_status(:created)
    end
  end
end
