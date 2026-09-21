require "rails_helper"

# The guards *are* the feature. Impersonation is an authentication bypass the
# company builds for itself, so every one of these examples covers a property
# that, if it silently stopped holding, would leave the bypass in place and the
# protection gone — with nothing visibly broken to notice.
RSpec.describe "Admin impersonation", type: :request do
  let(:admin) { create(:user, admin: true) }
  let(:organizer) { create(:user) }

  def impersonation_headers(session)
    { "Authorization" => "Bearer #{session.token}" }
  end

  # Every value stored under `key`, at any depth. Used by the PayWay guard so
  # it can't be fooled by a payload that nests the organization somewhere the
  # spec didn't anticipate.
  def deep_values(node, key)
    case node
    when Hash  then node.flat_map { |k, v| k == key ? [ v ] : deep_values(v, key) }
    when Array then node.flat_map { |v| deep_values(v, key) }
    else []
    end
  end

  def start_session(target = organizer, actor: admin, reason: "Checking their publish error from ticket 412")
    post "/api/v1/admin/impersonations",
         params: { user_id: target.id, reason: reason },
         headers: auth_headers(actor), as: :json
  end

  describe "opening a session" do
    it "returns a token and records who, whom and why" do
      expect { start_session }.to change(ImpersonationSession, :count).by(1)

      expect(response).to have_http_status(:created)
      expect(json["token"]).to be_present

      session = ImpersonationSession.last
      expect(session.admin).to eq(admin)
      expect(session.user).to eq(organizer)
      expect(session.reason).to include("ticket 412")
      expect(session).to be_live
    end

    it "writes an admin_actions row" do
      expect { start_session }.to change { AdminAction.where(action: "impersonate_user").count }.by(1)
    end

    it "404s for a non-admin" do
      post "/api/v1/admin/impersonations",
           params: { user_id: organizer.id, reason: "just having a look around" },
           headers: auth_headers(create(:user)), as: :json

      expect(response).to have_http_status(:not_found)
      expect(ImpersonationSession.count).to eq(0)
    end

    # The privilege-escalation case: impersonating an admin would launder one
    # staff member's actions through another's identity.
    it "refuses an admin target" do
      start_session(create(:user, admin: true))

      expect(response).to have_http_status(:unprocessable_content)
      expect(json["code"]).to eq("impersonation_admin_target")
    end

    it "refuses a suspended target" do
      organizer.suspend!(reason: "spam")

      start_session

      expect(response).to have_http_status(:unprocessable_content)
      expect(json["code"]).to eq("impersonation_unavailable")
    end

    it "refuses yourself" do
      start_session(admin)

      expect(json["code"]).to eq("impersonation_self")
    end

    it "requires a real reason" do
      start_session(organizer, reason: "asdf")

      expect(response).to have_http_status(:unprocessable_content)
      expect(ImpersonationSession.count).to eq(0)
    end

    # One live session per admin, by partial unique index *and* a matching
    # validation. Two simultaneous impersonations by one person is not a
    # workflow.
    it "refuses a second live session for the same admin" do
      start_session
      start_session(create(:user))

      expect(response).to have_http_status(:unprocessable_content)
      expect(ImpersonationSession.count).to eq(1)
    end
  end

  # The invariant the whole transparency argument rests on.
  describe "telling the user" do
    it "writes them a notification" do
      expect { start_session }
        .to change { Notification.where(user: organizer, kind: "account_impersonated").count }.by(1)

      expect(Notification.last.body).to include("ticket 412")
    end

    it "emails them" do
      expect { start_session }.to have_enqueued_mail(ImpersonationMailer, :account_accessed)
    end

    # "A session existed that the user was never told about" must not be a
    # state the database can hold — so the notification failing has to take the
    # session with it, not be swallowed the way every other notifier's is.
    it "creates no session if the notification can't be written" do
      allow(Notifications::ImpersonationNotifier).to receive(:started)
        .and_raise(ActiveRecord::RecordInvalid.new(Notification.new))

      expect { start_session }.to raise_error(ActiveRecord::RecordInvalid)
        .or change(ImpersonationSession, :count).by(0)

      expect(ImpersonationSession.count).to eq(0)
    end
  end

  describe "what the session can do" do
    let(:session) { ImpersonationSession.start!(admin: admin, user: organizer, reason: "looking into ticket 412") }

    it "reads as the target" do
      get "/api/v1/auth/me", headers: impersonation_headers(session)

      expect(response).to have_http_status(:ok)
      expect(json["user"]["id"]).to eq(organizer.id)
      expect(json["impersonation"]["by_admin"]).to be(true)
      expect(json["impersonation"]["reason"]).to include("ticket 412")
    end

    # The whole point of keeping `user_id` as the target in the token: this
    # endpoint has no idea impersonation exists, and answers for the organizer
    # anyway.
    it "sees the target's own dashboard" do
      create(:event, creator: organizer, title: "Their Own Event")

      get "/api/v1/events/my", headers: impersonation_headers(session)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Their Own Event")
    end

    # Read-only is enforced on the *verb*, not a list of endpoints, so this
    # holds for endpoints nobody has written yet. Each verb is checked
    # separately because the guard is one condition per verb and a typo in one
    # branch would be invisible from the others.
    it "refuses every write verb" do
      event = create(:event, creator: organizer)

      post "/api/v1/events", params: { event: { title: "New" } },
           headers: impersonation_headers(session), as: :json
      expect(response).to have_http_status(:forbidden)
      expect(json["code"]).to eq("impersonation_read_only")

      patch "/api/v1/events/#{event.id}", params: { event: { title: "Changed" } },
            headers: impersonation_headers(session), as: :json
      expect(response).to have_http_status(:forbidden)

      delete "/api/v1/events/#{event.id}", headers: impersonation_headers(session)
      expect(response).to have_http_status(:forbidden)

      expect(event.reload.title).not_to eq("Changed")
    end

    # Account and identity are covered by the verb rule with nothing extra —
    # pinned because the request named them explicitly, and because a future
    # "safe write" exemption would have to break this to ship.
    it "cannot change the password, the email or delete the account" do
      patch "/api/v1/auth/password",
            params: { current_password: "password123", new_password: "newpassword123",
                      new_password_confirmation: "newpassword123" },
            headers: impersonation_headers(session), as: :json
      expect(response).to have_http_status(:forbidden)

      delete "/api/v1/auth/account", params: { current_password: "password123" },
             headers: impersonation_headers(session), as: :json
      expect(response).to have_http_status(:forbidden)

      expect(organizer.reload.authenticate("password123")).to be_truthy
    end

    # Read-only protects the user's data from staff; it does nothing about the
    # user's secrets, which are readable by definition.
    it "does not expose PayWay credentials, but does say whether they're set up" do
      organization = create(:organization, owner: organizer,
                                           payway_merchant_id: "merchant_123",
                                           payway_api_key: "secret-key-value")

      # The control. Without it, the nils below would pass just as happily
      # against an endpoint that never returned these keys at all — which is
      # exactly how the first version of this example passed while reading the
      # wrong level of the payload.
      get "/api/v1/profile", headers: auth_headers(organizer)
      expect(json["profile"]["payway_merchant_id"]).to eq("merchant_123")
      expect(json["profile"]["payway_hidden"]).to be(false)

      get "/api/v1/profile", headers: impersonation_headers(session)

      expect(response).to have_http_status(:ok)
      profile = json["profile"]
      expect(profile).to have_key("payway_merchant_id")
      expect(profile["payway_merchant_id"]).to be_nil
      expect(profile["payway_api_key_masked"]).to be_nil
      expect(profile["payway_hidden"]).to be(true)
      # The boolean stays: "is my payment setup complete" is one of the most
      # common things support is asked, and a flag saying whether a credential
      # exists is not the credential.
      expect(profile["payway_configured"]).to be(true)
    end

    # `subscribed` runs once and a socket lives for hours; a 30-minute token is
    # the same shape. Without re-reading the actor, demoting or suspending a
    # staff account left their open session working right through an
    # offboarding.
    it "stops working when the actor stops being an admin" do
      admin.update!(admin: false)

      get "/api/v1/auth/me", headers: impersonation_headers(session)

      expect(response).to have_http_status(:unauthorized)
      expect(json["code"]).to eq("impersonation_ended")
    end

    it "stops working when the actor is suspended" do
      admin.suspend!(reason: "offboarded")

      get "/api/v1/auth/me", headers: impersonation_headers(session)

      expect(response).to have_http_status(:unauthorized)
    end

    it "stops working when the actor's account is deleted" do
      admin.discard!

      get "/api/v1/auth/me", headers: impersonation_headers(session)

      expect(response).to have_http_status(:unauthorized)
    end

    # Two mechanisms guard this, and this one is the token-level half: even if
    # the endpoint check were relaxed, an impersonation token still can't reach
    # the console.
    it "cannot reach the admin console" do
      get "/api/v1/admin/users", headers: impersonation_headers(session)

      expect(response).to have_http_status(:not_found)
    end

    # Two guards refuse this and the *verb* one wins, because it runs inside
    # authentication and `require_admin!` is a later filter. 403 rather than
    # the 404 the console gives, therefore — pinned as 403 so that if the
    # ordering ever changes, the reason shows up here rather than as a
    # confusing status in production.
    it "cannot open another impersonation session" do
      post "/api/v1/admin/impersonations",
           params: { user_id: create(:user).id, reason: "chaining sessions together" },
           headers: impersonation_headers(session), as: :json

      expect(response).to have_http_status(:forbidden)
      expect(json["code"]).to eq("impersonation_read_only")
      expect(ImpersonationSession.count).to eq(1)
    end

    # POST /cable/ticket is a write by the verb rule, so a support session gets
    # no WebSocket — which is the right answer anyway, since staff are the other
    # side of support chat.
    it "cannot open a WebSocket" do
      post "/api/v1/cable/ticket", headers: impersonation_headers(session), as: :json

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "ending" do
    let!(:session) { ImpersonationSession.start!(admin: admin, user: organizer, reason: "looking into ticket 412") }

    it "stops the token working" do
      delete "/api/v1/admin/impersonations/current", headers: auth_headers(admin)
      expect(response).to have_http_status(:ok)

      get "/api/v1/auth/me", headers: impersonation_headers(session)
      expect(response).to have_http_status(:unauthorized)
      expect(json["code"]).to eq("impersonation_ended")
    end

    it "is idempotent" do
      delete "/api/v1/admin/impersonations/current", headers: auth_headers(admin)
      delete "/api/v1/admin/impersonations/current", headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(json["ended"]).to be(false)
    end

    # Any admin can kill any live session: the case this exists for is the
    # laptop left open in a café, and a control only its own holder can pull is
    # not a control.
    it "can be revoked by a different admin" do
      other = create(:user, admin: true)

      post "/api/v1/admin/impersonations/#{session.id}/revoke", headers: auth_headers(other)

      expect(session.reload.revoked_by).to eq(other)
      get "/api/v1/auth/me", headers: impersonation_headers(session)
      expect(response).to have_http_status(:unauthorized)
      # The token is still perfectly valid here — only the row says otherwise,
      # which is the whole reason the row exists. Contrast the expiry example.
      expect(json["code"]).to eq("impersonation_ended")
    end

    # Expiry is evaluated, never stored — no job has to run for a session to
    # stop working.
    #
    # It comes back as a plain 401 with **no** `impersonation_ended` code, and
    # that's structural rather than an oversight: the JWT's `exp` is set from
    # the same `expires_at` as the row, so on natural expiry the token is
    # already undecodable and the row check never runs. `impersonation_ended`
    # is the code for a session killed *early* — ended or revoked — where the
    # token is still valid and only the row says otherwise. The frontend
    # doesn't distinguish (any failure with an impersonation key present drops
    # that key), but a reader of this code would expect one code for both, so
    # the difference is pinned here.
    it "expires on its own with nothing having run" do
      travel_to(ImpersonationSession::DURATION.from_now + 1.minute) do
        get "/api/v1/auth/me", headers: impersonation_headers(session)

        expect(response).to have_http_status(:unauthorized)
        expect(json["code"]).to be_nil
      end
    end

    # Both already refused on every request by authenticate_user!, so the
    # session dies with the account and needs no code of its own.
    it "stops working when the target is suspended mid-session" do
      organizer.suspend!(reason: "spam")

      get "/api/v1/auth/me", headers: impersonation_headers(session)

      expect(response).to have_http_status(:forbidden)
    end
  end

  # `authenticate_user_optional!` and `identify_current_user!` both promise, at
  # length, never to render — a public page and guest checkout were never gated
  # on sign-in. An earlier version of the impersonation guard rendered a 401
  # from inside them, so a forgotten key in localStorage turned an ungated
  # route into an error page.
  describe "a dead session on an endpoint that doesn't require auth" do
    let(:event) { create(:event, creator: organizer, title: "Still Public") }
    let(:dead) do
      ImpersonationSession.start!(admin: admin, user: organizer, reason: "session that gets revoked")
        .tap { |s| s.revoke!(by: admin) }
    end

    it "renders the public page anonymously rather than 401ing" do
      get "/api/v1/events/#{event.id}", headers: impersonation_headers(dead)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Still Public")
    end

    # The half that must NOT soften. Degrading to anonymous on a write would
    # let a support session perform a guest-checkout registration — read-only
    # failing open in exactly the place it matters most.
    it "still refuses a write from a *live* session on the same kind of endpoint" do
      live = ImpersonationSession.start!(admin: create(:user, admin: true), user: create(:user),
                                         reason: "live session for the write check")

      post "/api/v1/events/#{event.id}/reports",
           params: { report: { reason: "other", details: "testing the guest path" } },
           headers: impersonation_headers(live), as: :json

      expect(response).to have_http_status(:forbidden)
      expect(json["code"]).to eq("impersonation_read_only")
      expect(EventReport.count).to eq(0)
    end
  end

  # D3 in the design doc, and the promise the notification email makes to the
  # user in as many words. Two guards: one behavioural, one structural.
  describe "PayWay credentials" do
    let(:session) { ImpersonationSession.start!(admin: admin, user: organizer, reason: "checking their payment setup") }

    before do
      create(:organization, owner: organizer, payway_merchant_id: "merchant_123",
                            payway_api_key: "secret-key-value")
    end

    it "never appear in any impersonated GET that carries them" do
      %w[/api/v1/profile /api/v1/organizations].each do |path|
        get path, headers: impersonation_headers(session)

        expect(response).to have_http_status(:ok)
        # Deep scan rather than a known key path: a payload that nests the
        # organization somewhere new would slip past an assertion written
        # against today's shape.
        found = deep_values(JSON.parse(response.body), "payway_merchant_id")
        expect(found).to all(be_nil), "#{path} leaked #{found.compact.inspect}"
      end
    end

    # The behavioural spec above can only cover endpoints someone thought to
    # list. This one covers the one that doesn't exist yet: `ApplicationController`
    # is the single place allowed to serialize the identifiers, so a third
    # serializer fails here rather than shipping. Same kind of boundary-crossing
    # guard as the conversation-retention spec that reads the frontend locales —
    # the failure it prevents is a promise made to a user becoming false.
    it "are serialized in exactly one place" do
      offenders = Dir[Rails.root.join("app/controllers/**/*.rb")].reject do |file|
        file.end_with?("application_controller.rb")
      end.select do |file|
        File.read(file).match?(/payway_merchant_id:\s|payway_api_key_masked:\s/)
      end

      expect(offenders).to be_empty,
        "these serialize PayWay identifiers directly; route them through " \
        "ApplicationController#payway_identity_fields instead:\n  " +
        offenders.map { |f| f.sub("#{Rails.root}/", "") }.join("\n  ")
    end
  end

  # Two definitions of one predicate in two languages drift, and nobody reports
  # which of them is wrong — the queue just looks odd.
  describe "ImpersonationSession.live and #live? agree" do
    it "across ended, revoked, expired and open" do
      open_session = ImpersonationSession.start!(admin: admin, user: organizer, reason: "open session here")
      ended = ImpersonationSession.start!(admin: create(:user, admin: true), user: create(:user), reason: "ended session here").tap(&:end!)
      revoked = ImpersonationSession.start!(admin: create(:user, admin: true), user: create(:user), reason: "revoked session here")
                                    .tap { |s| s.revoke!(by: admin) }
      expired = ImpersonationSession.start!(admin: create(:user, admin: true), user: create(:user), reason: "expired session here")
      expired.update_columns(expires_at: 1.minute.ago)

      in_sql = ImpersonationSession.live.pluck(:id)

      [ open_session, ended, revoked, expired ].each do |session|
        expect(in_sql.include?(session.id)).to eq(session.reload.live?),
          "disagreement on #{session.reason}"
      end
    end
  end
end
