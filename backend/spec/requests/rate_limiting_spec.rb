require "rails_helper"

# These examples are tagged :rack_attack because throttling is disabled in the
# test env by default — see spec/support/rack_attack.rb.
RSpec.describe "Rate limiting", type: :request, rack_attack: true do
  let(:password) { "password123" }

  describe "sign-in throttling" do
    let!(:user) { create(:user, password: password) }

    it "returns 429 with a JSON body and Retry-After once the burst limit is exceeded" do
      # Limit is 6 per 20s — the 7th should be throttled. Wrong password on
      # purpose: throttling has to apply to failed attempts, since that's the
      # credential-stuffing case it exists for.
      7.times do
        post "/api/v1/auth/signin", params: { email: user.email, password: "wrong" }, as: :json
      end

      expect(response).to have_http_status(:too_many_requests)
      expect(json["code"]).to eq("rate_limited")
      expect(json["error"]).to be_present
      expect(response.headers["Retry-After"]).to be_present
    end

    it "throttles by email address even when the request IPs differ" do
      # 12 per 20 minutes keyed on email. Vary the IP each time so the
      # per-IP limits can't be what's tripping — this proves the per-email
      # key is doing the work, which is the distributed-attack case.
      13.times do |i|
        post "/api/v1/auth/signin",
             params: { email: user.email, password: "wrong" },
             headers: { "REMOTE_ADDR" => "203.0.113.#{i + 1}" },
             as: :json
      end

      expect(response).to have_http_status(:too_many_requests)
    end

    it "keys the email throttle on the normalized address" do
      # Mixed case / surrounding whitespace must share a counter with the
      # plain form, otherwise the limit is trivially bypassed by retyping.
      12.times do |i|
        post "/api/v1/auth/signin",
             params: { email: "  #{user.email.upcase}  ", password: "wrong" },
             headers: { "REMOTE_ADDR" => "198.51.100.#{i + 1}" },
             as: :json
      end

      post "/api/v1/auth/signin",
           params: { email: user.email, password: "wrong" },
           headers: { "REMOTE_ADDR" => "198.51.100.200" },
           as: :json

      expect(response).to have_http_status(:too_many_requests)
    end

    it "lets a normal number of attempts through untouched" do
      post "/api/v1/auth/signin", params: { email: user.email, password: password }, as: :json

      expect(response).to have_http_status(:ok)
      expect(json["token"]).to be_present
    end
  end

  describe "password reset throttling" do
    it "returns 429 after 5 requests for the same email in an hour" do
      user = create(:user)

      6.times do |i|
        post "/api/v1/password_resets",
             params: { email: user.email },
             headers: { "REMOTE_ADDR" => "192.0.2.#{i + 1}" },
             as: :json
      end

      expect(response).to have_http_status(:too_many_requests)
    end
  end

  describe "signup throttling" do
    it "returns 429 after 10 signups from one IP in an hour" do
      11.times do |i|
        post "/api/v1/auth/signup",
             params: { email: "user#{i}@example.com", password: password },
             as: :json
      end

      expect(response).to have_http_status(:too_many_requests)
    end
  end

  describe "uploads throttling" do
    let(:tiny_png) do
      # 1x1 transparent PNG — small enough to embed inline rather than
      # needing a spec/fixtures file (see rack_attack.rb's "uploads/user"
      # throttle, added for issue #282).
      bytes = Base64.decode64(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
      )
      file = Tempfile.new(["tiny", ".png"], binmode: true)
      file.write(bytes)
      file.rewind
      Rack::Test::UploadedFile.new(file.path, "image/png")
    end

    it "throttles by account even when the request IPs differ, once the per-user limit is exceeded" do
      user = create(:user)
      headers = auth_headers(user)

      # 30 per 10 minutes keyed on user id. Vary the IP each time so the
      # per-IP throttle can't be what's tripping — same reasoning as the
      # signin/email spec above, applied to "uploads/user".
      31.times do |i|
        post "/api/v1/uploads",
             params: { file: tiny_png, type: "avatar" },
             headers: headers.merge("REMOTE_ADDR" => "203.0.113.#{i + 1}")
      end

      expect(response).to have_http_status(:too_many_requests)
      expect(json["code"]).to eq("rate_limited")
    end

    it "lets a normal number of uploads through untouched" do
      user = create(:user)

      post "/api/v1/uploads", params: { file: tiny_png, type: "avatar" }, headers: auth_headers(user)

      expect(response).to have_http_status(:created)
      expect(json["url"]).to be_present
    end
  end

  describe "invitations throttling" do
    let!(:event) { create(:event) }

    it "throttles by inviting account even when target emails and IPs differ, " \
       "once the per-user limit is exceeded" do
      headers = auth_headers(event.creator)

      # 20 per 10 minutes keyed on the inviter's user id. Vary both the
      # target email and the IP each time so neither the per-email nor the
      # per-IP throttle can be what's tripping — this isolates
      # "invitations/user".
      21.times do |i|
        post "/api/v1/events/#{event.id}/invitations",
             params: { email: "team-member-#{i}@example.com", role: "viewer" },
             headers: headers.merge("REMOTE_ADDR" => "203.0.113.#{i + 1}"), as: :json
      end

      expect(response).to have_http_status(:too_many_requests)
      expect(json["code"]).to eq("rate_limited")
    end

    it "throttles invites to the same target email even when the inviting IP differs" do
      headers = auth_headers(event.creator)

      # 5 per hour keyed on the target email — well under the per-user
      # limit of 20, so this proves "invitations/email" on its own. Vary the
      # IP each time, same reasoning as the signin/email spec above.
      6.times do |i|
        post "/api/v1/events/#{event.id}/invitations",
             params: { email: "persistent-invitee@example.com", role: "viewer" },
             headers: headers.merge("REMOTE_ADDR" => "198.51.100.#{i + 1}"), as: :json
      end

      expect(response).to have_http_status(:too_many_requests)
    end

    it "lets a normal invitation through untouched" do
      post "/api/v1/events/#{event.id}/invitations",
           params: { email: "new-teammate@example.com", role: "viewer" },
           headers: auth_headers(event.creator), as: :json

      expect(response).to have_http_status(:created)
      expect(json["invitation"]["email"]).to eq("new-teammate@example.com")
    end
  end

  describe "payments throttling" do
    it "returns 429 after 30 payment requests from one IP in 10 minutes" do
      # Covers both the POST .../payments and GET /payments/:id shapes under
      # one counter — see rack_attack.rb's "payments/ip" throttle. A
      # not-found id is enough to exercise the path match without touching
      # the ABA PayWay gateway.
      31.times do
        get "/api/v1/payments/00000000-0000-0000-0000-000000000000", as: :json
      end

      expect(response).to have_http_status(:too_many_requests)
    end
  end

  describe "cable ticket throttling" do
    let!(:user) { create(:user, password: password) }

    # Keyed on the JWT's user_id, so one account can't dodge the limit by
    # changing networks. Every call writes into the shared cache, which is what
    # makes a loop here worth bounding beyond the generic req/ip backstop.
    it "throttles per user once the limit is exceeded" do
      headers = auth_headers(user)

      31.times { post "/api/v1/cable/ticket", headers: headers }

      expect(response).to have_http_status(:too_many_requests)
      expect(json["code"]).to eq("rate_limited")
    end

    it "leaves a second account unaffected" do
      other = create(:user, password: password)
      mine = auth_headers(user)
      theirs = auth_headers(other)

      31.times { post "/api/v1/cable/ticket", headers: mine }
      expect(response).to have_http_status(:too_many_requests)

      post "/api/v1/cable/ticket", headers: theirs
      expect(response).to have_http_status(:created)
    end
  end

  describe "safelisted paths" do
    it "never throttles the ABA PayWay webhook" do
      # Well past every limit, including the blanket req/ip one.
      305.times do
        post "/api/v1/webhooks/aba_payway", params: { merchant_ref: "unknown" }, as: :json
      end

      expect(response).to have_http_status(:ok)
    end

    it "never throttles the health check" do
      305.times { get "/up" }

      expect(response).to have_http_status(:ok)
    end
  end
end
