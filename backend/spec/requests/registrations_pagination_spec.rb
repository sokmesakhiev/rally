require "rails_helper"

RSpec.describe "Participant list pagination", type: :request do
  let(:organizer) { create(:user) }
  let(:event) { create(:event, creator: organizer) }
  let(:headers) { auth_headers(organizer) }

  def named(display_name, email: nil)
    user = create(:user, **(email ? { email: email } : {}))
    user.profile.update!(display_name: display_name)
    create(:registration, event: event, user: user)
  end

  describe "GET /api/v1/events/:event_id/registrations" do
    it "returns the first page and the totals needed to page through" do
      create_list(:registration, 30, event: event)

      get "/api/v1/events/#{event.id}/registrations", headers: headers

      expect(response).to have_http_status(:ok)
      expect(json["registrations"].length).to eq(25)
      expect(json["meta"]).to include(
        "page" => 1, "per_page" => 25, "total_count" => 30, "total_pages" => 2
      )
    end

    it "returns the remainder on the last page" do
      create_list(:registration, 30, event: event)

      get "/api/v1/events/#{event.id}/registrations?page=2", headers: headers

      expect(json["registrations"].length).to eq(5)
      expect(json["meta"]["page"]).to eq(2)
    end

    it "returns an empty page rather than erroring past the end" do
      create_list(:registration, 3, event: event)

      get "/api/v1/events/#{event.id}/registrations?page=99", headers: headers

      expect(response).to have_http_status(:ok)
      expect(json["registrations"]).to be_empty
      expect(json["meta"]["total_count"]).to eq(3)
    end

    it "honours per_page" do
      create_list(:registration, 10, event: event)

      get "/api/v1/events/#{event.id}/registrations?per_page=4", headers: headers

      expect(json["registrations"].length).to eq(4)
      expect(json["meta"]["total_pages"]).to eq(3)
    end

    # A 422 rather than silently serving page 1 — see the schema's comment.
    it "rejects an uncoercible page instead of pretending it worked" do
      get "/api/v1/events/#{event.id}/registrations?page=abc", headers: headers

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "rejects a per_page above the ceiling" do
      get "/api/v1/events/#{event.id}/registrations?per_page=100000", headers: headers

      expect(response).to have_http_status(:unprocessable_content)
    end

    # This endpoint previously returned everything with no params, so anything
    # already calling it has to keep working — it just gets page one.
    it "still works with no parameters at all" do
      create_list(:registration, 3, event: event)

      get "/api/v1/events/#{event.id}/registrations", headers: headers

      expect(response).to have_http_status(:ok)
      expect(json["registrations"].length).to eq(3)
    end
  end

  describe "search" do
    it "matches on display name, case-insensitively" do
      named("Sokmesa Khiev")
      named("Someone Else")

      get "/api/v1/events/#{event.id}/registrations?q=sokmesa", headers: headers

      expect(json["registrations"].length).to eq(1)
      expect(json["meta"]["total_count"]).to eq(1)
    end

    it "matches on email too" do
      named("No Name Here", email: "findme@example.com")
      named("Someone Else")

      get "/api/v1/events/#{event.id}/registrations?q=findme", headers: headers

      expect(json["registrations"].length).to eq(1)
    end

    # total_count has to describe the *filtered* set, or the pager offers
    # pages that don't exist.
    it "counts the filtered set, not the whole list" do
      create_list(:registration, 40, event: event)
      named("Unique Person")

      get "/api/v1/events/#{event.id}/registrations?q=Unique", headers: headers

      expect(json["meta"]["total_count"]).to eq(1)
      expect(json["meta"]["total_pages"]).to eq(1)
    end

    # sanitize_sql_like — a name containing % must search for that character
    # rather than matching everybody.
    it "treats LIKE wildcards in the query as literal characters" do
      named("100% Effort")
      create_list(:registration, 5, event: event)

      get "/api/v1/events/#{event.id}/registrations?q=100%25", headers: headers

      expect(json["registrations"].length).to eq(1)
    end

    it "treats a blank query as no filter" do
      create_list(:registration, 3, event: event)

      get "/api/v1/events/#{event.id}/registrations?q=", headers: headers

      expect(json["registrations"].length).to eq(3)
    end
  end

  describe "GET /api/v1/events/:event_id/registrations/summary" do
    it "returns totals over the whole event, not a page" do
      create_list(:registration, 30, event: event, payment_status: "paid", amount_paid_cents: 1000)

      get "/api/v1/events/#{event.id}/registrations/summary", headers: headers

      expect(response).to have_http_status(:ok)
      expect(json["summary"]).to include(
        "total" => 30, "paid" => 30, "revenue_cents" => 30_000
      )
    end

    it "404s for someone who can't view participants" do
      get "/api/v1/events/#{event.id}/registrations/summary", headers: auth_headers(create(:user))

      expect(response).to have_http_status(:not_found)
    end

    # The literal /summary segment must not be swallowed by any :id route.
    it "is not shadowed by another registrations route" do
      get "/api/v1/events/#{event.id}/registrations/summary", headers: headers

      expect(json).to have_key("summary")
      expect(json).not_to have_key("registrations")
    end
  end
end
