require "rails_helper"

# The user detail sheet and the `last_seen_at` stamp behind it.
#
# The stamp is the part worth testing. It runs on *every authenticated
# request*, which makes it the single most-executed line of application code in
# the app — so each way it could be wrong is a way to be wrong everywhere at
# once, from a suspension that stops working to a write on the hot path.
RSpec.describe "Admin user details", type: :request do
  let!(:colleague) { create(:user, :admin) }
  let(:admin)      { create(:user, :admin) }
  let(:organizer)  { create(:user) }

  describe "recording last_seen_at" do
    it "stamps on an authenticated request" do
      headers = auth_headers(organizer)
      expect(organizer.reload.last_seen_at).to be_nil

      get "/api/v1/auth/me", headers: headers

      expect(response).to have_http_status(:ok)
      expect(organizer.reload.last_seen_at).to be_within(5.seconds).of(Time.current)
    end

    it "does not move updated_at" do
      # `update_column`, not `touch`. If activity moved `updated_at`, every row
      # in `users` would report "last seen" under a column name that claims to
      # mean "last changed", and nothing would record account edits any more.
      headers = auth_headers(organizer)
      before = organizer.reload.updated_at

      get "/api/v1/auth/me", headers: headers

      expect(organizer.reload.updated_at).to eq(before)
    end

    it "writes at most once per throttle window" do
      # The whole reason this is affordable. Without the throttle every read
      # the API serves carries an UPDATE, on a web task with three Puma
      # threads.
      headers = auth_headers(organizer)
      get "/api/v1/auth/me", headers: headers
      first = organizer.reload.last_seen_at

      travel_to(User::LAST_SEEN_THROTTLE.from_now - 1.minute) do
        get "/api/v1/auth/me", headers: headers
      end

      expect(organizer.reload.last_seen_at).to eq(first)
    end

    it "writes again once the window has passed" do
      headers = auth_headers(organizer)
      get "/api/v1/auth/me", headers: headers
      first = organizer.reload.last_seen_at

      travel_to(User::LAST_SEEN_THROTTLE.from_now + 1.minute) do
        get "/api/v1/auth/me", headers: headers
        expect(organizer.reload.last_seen_at).to be > first
      end
    end

    it "does not stamp for an impersonated request" do
      # The one that actually matters. These requests are staff's, not the
      # user's — attributing them here would mean an admin checking whether an
      # account is dormant marks it active by looking, and "last seen" would
      # report on Rally's own support team. ImpersonationSession is the record
      # of that activity.
      session = ImpersonationSession.start!(
        admin: admin, user: organizer, reason: "looking into ticket 412"
      )

      get "/api/v1/auth/me", headers: { "Authorization" => "Bearer #{session.token}" }

      expect(response).to have_http_status(:ok)
      expect(organizer.reload.last_seen_at).to be_nil
    end

    it "does not stamp for a suspended account" do
      # The suspension branch returns before the stamp. A blocked request is
      # not "seen" — and an account suspended for abuse should not keep
      # looking active because its old token is still being retried.
      headers = auth_headers(organizer)
      organizer.suspend!(reason: "Reported")

      get "/api/v1/auth/me", headers: headers

      expect(response).to have_http_status(:forbidden)
      expect(organizer.reload.last_seen_at).to be_nil
    end
  end

  describe "GET /api/v1/admin/users/:id" do
    it "returns the account, its state and its activity" do
      event = create(:event, creator: organizer)
      registration = create(:registration, user: organizer, event: event)
      create(:payment, :approved, registration: registration,
                                  amount_cents: 24_000, currency: "usd")

      get "/api/v1/admin/users/#{organizer.id}", headers: auth_headers(admin), as: :json

      expect(response).to have_http_status(:ok)
      expect(json["user"]["email"]).to eq(organizer.email)
      expect(json["user"]).to have_key("last_seen_at")

      activity = json["user"]["activity"]
      expect(activity["events_count"]).to eq(1)
      expect(activity["registrations_count"]).to eq(1)
      expect(activity["paid"]).to eq(
        [ { "currency" => "usd", "gross_cents" => 24_000, "refunded_cents" => 0 } ]
      )
    end

    it "keeps each currency on its own line rather than summing them" do
      # Adding KHR to USD produces a number that is wrong while still looking
      # like money — the same failure the manage dashboard's revenue card had
      # when it summed a single page.
      usd = create(:registration, user: organizer)
      khr = create(:registration, user: organizer)
      create(:payment, :approved, registration: usd, amount_cents: 1_000, currency: "usd")
      create(:payment, :approved, registration: khr, amount_cents: 40_000, currency: "khr")

      get "/api/v1/admin/users/#{organizer.id}", headers: auth_headers(admin), as: :json

      expect(json["user"]["activity"]["paid"].map { |r| r["currency"] })
        .to contain_exactly("usd", "khr")
    end

    it "ignores payments that never settled" do
      registration = create(:registration, user: organizer)
      create(:payment, registration: registration, amount_cents: 9_900, status: "pending")

      get "/api/v1/admin/users/#{organizer.id}", headers: auth_headers(admin), as: :json

      # A KHQR code nobody scanned is not money this person paid.
      expect(json["user"]["activity"]["paid"]).to be_empty
    end

    it "404s for a non-admin rather than admitting the route exists" do
      get "/api/v1/admin/users/#{organizer.id}", headers: auth_headers(organizer), as: :json

      expect(response).to have_http_status(:not_found)
    end

    it "404s for an unknown user" do
      get "/api/v1/admin/users/#{SecureRandom.uuid}", headers: auth_headers(admin), as: :json

      expect(response).to have_http_status(:not_found)
    end

    it "is readable by support, who answer questions about accounts" do
      # `:read_users`, the same capability the list carries — the sheet shows
      # what the list shows plus aggregates over the same person's records, so
      # gating it harder would be a distinction without a difference.
      support = create(:user, :support)

      get "/api/v1/admin/users/#{organizer.id}", headers: auth_headers(support), as: :json

      expect(response).to have_http_status(:ok)
    end
  end
end
