require "rails_helper"

RSpec.describe "Cable tickets", :with_cache, type: :request do
  let(:user) { create(:user) }

  describe "POST /api/v1/cable/ticket" do
    it "requires a session" do
      post "/api/v1/cable/ticket"

      expect(response).to have_http_status(:unauthorized)
    end

    it "returns a ticket that redeems to the caller" do
      post "/api/v1/cable/ticket", headers: auth_headers(user)

      expect(response).to have_http_status(:created)
      body = response.parsed_body
      expect(body["expires_in"]).to eq(Cable::Ticket::TTL.to_i)
      expect(Cable::Ticket.redeem(body["ticket"])).to eq(user)
    end

    # Every reconnect needs its own, since tickets are single-use — and
    # ActionCable reconnects on its own after every deploy.
    it "issues a fresh ticket per call" do
      headers = auth_headers(user)

      post "/api/v1/cable/ticket", headers: headers
      first = response.parsed_body["ticket"]
      post "/api/v1/cable/ticket", headers: headers
      second = response.parsed_body["ticket"]

      expect(first).not_to eq(second)
      expect(Cable::Ticket.redeem(first)).to eq(user)
      expect(Cable::Ticket.redeem(second)).to eq(user)
    end
  end
end
