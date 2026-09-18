require "rails_helper"

# The compensating control for the one segment the report queue can't see.
#
# An unlisted event is absent from the catalogue and from search, so there is
# no audience to report it — and "invite-only, not listed, carefully worded" is
# exactly the shape of the gatherings Rally refuses to host. Reporting scales
# with audience; this doesn't need one.
RSpec.describe "Large unlisted events need a verified organization", type: :request do
  let(:owner) { create(:user, verified_at: Time.current) }

  # Every paid plan opens a KHQR payment, so any example that expects to get
  # *past* the gate has to stub the gateway or it fails on an outbound call.
  let(:qr_response) do
    {
      status: { code: "0", message: "Success", trace_id: "trace-1" },
      qrString: "00020101...",
      abapay_deeplink: "abamobilebank://ababank.com?type=payway&qrcode=..."
    }
  end

  def organization(verified:)
    create(:organization, owner: owner, verified_at: verified ? Time.current : nil)
  end

  def publish(event, plan:)
    post "/api/v1/events/#{event.id}/plan_payments",
         params: { plan: plan }, headers: auth_headers(owner), as: :json
  end

  describe "at publish" do
    it "refuses a large unlisted event from an unverified organization" do
      event = create(:event, :draft, creator: owner, organization: organization(verified: false),
                                     visibility: "unlisted")

      publish(event, plan: "small")

      expect(response).to have_http_status(:unprocessable_content)
      expect(json["code"]).to eq("verification_required")
      expect(event.reload.is_published).to be(false)
    end

    # A *paid* plan doesn't publish here — it opens a KHQR payment, and
    # `EventPlanPayment#mark_paid!` is what sets is_published later. So what
    # passing the gate looks like is "the charge was allowed to start", not a
    # published event.
    it "allows it once the organization is verified" do
      allow_any_instance_of(AbaPayway::Client).to receive(:generate_qr).and_return(qr_response)
      event = create(:event, :draft, creator: owner, organization: organization(verified: true),
                                     visibility: "unlisted")

      publish(event, plan: "small")

      expect(response).to have_http_status(:created)
      expect(json["plan_payment"]["status"]).to eq("pending")
    end

    # A threshold, not a blanket rule: a small private club ride isn't the
    # risk, and taxing it to reach the rare case is the wrong trade.
    it "leaves a small unlisted event alone" do
      event = create(:event, :draft, creator: owner, organization: organization(verified: false),
                                     visibility: "unlisted")

      publish(event, plan: "free")

      expect(event.reload.is_published).to be(true)
    end

    it "leaves a large *public* event alone — the catalogue is the control there" do
      allow_any_instance_of(AbaPayway::Client).to receive(:generate_qr).and_return(qr_response)
      event = create(:event, :draft, creator: owner, organization: organization(verified: false),
                                     visibility: "public")

      publish(event, plan: "small")

      expect(response).to have_http_status(:created)
    end

    # The check runs before any charge is started, for the same reason the
    # organization-identity and plan-capacity checks do: charging an organizer
    # and then refusing to publish is the outcome to avoid.
    it "takes no payment when it refuses" do
      event = create(:event, :draft, creator: owner, organization: organization(verified: false),
                                     visibility: "unlisted")

      expect { publish(event, plan: "small") }.not_to change(EventPlanPayment, :count)
    end
  end

  # The path that doesn't go through payment at all, and would otherwise be a
  # one-PATCH bypass of the guard above.
  describe "flipping an already-published event to unlisted" do
    it "is refused when the organization isn't verified and the event is large" do
      event = create(:event, creator: owner, organization: organization(verified: false),
                             visibility: "public", capacity: 200)

      patch "/api/v1/events/#{event.id}",
            params: { event: { visibility: "unlisted" } },
            headers: auth_headers(owner), as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(event.reload).to be_listed
    end

    it "is allowed for a verified organization" do
      event = create(:event, creator: owner, organization: organization(verified: true),
                             visibility: "public", capacity: 200)

      patch "/api/v1/events/#{event.id}",
            params: { event: { visibility: "unlisted" } },
            headers: auth_headers(owner), as: :json

      expect(event.reload).to be_unlisted
    end
  end

  # The third way into the guarded state, and the one that moves neither
  # `visibility` nor `is_published`: an unlisted event published small and then
  # grown. `EventPlanPaymentsController` refuses this before charging, so this
  # covers the model backstop for any path that doesn't go through it.
  describe "growing an already-published unlisted event" do
    it "is refused when the organization isn't verified" do
      event = create(:event, :draft, creator: owner, organization: organization(verified: false),
                                     visibility: "unlisted")
      event.update_columns(is_published: true, capacity: 20)

      expect { event.reload.update!(capacity: 5_000) }
        .to raise_error(ActiveRecord::RecordInvalid, /needs a verified organization/)
    end

    it "is allowed for a verified organization" do
      event = create(:event, :draft, creator: owner, organization: organization(verified: true),
                                     visibility: "unlisted")
      event.update_columns(is_published: true, capacity: 20)

      expect { event.reload.update!(capacity: 5_000) }.not_to raise_error
    end

    # Growth is the trigger, not saving: a large grandfathered event whose
    # capacity isn't changing stays editable.
    it "leaves an unrelated edit on a large existing event alone" do
      event = create(:event, creator: owner, organization: organization(verified: false),
                             visibility: "public")
      event.update_columns(visibility: "unlisted", capacity: 200)

      expect { event.reload.update!(title: "Still Editable") }.not_to raise_error
    end
  end

  # Creating one published, unlisted and large in a single step is a
  # transition into the guarded state too, so it is refused. Nothing in the
  # app does this today — events are created as drafts and published through
  # a plan payment — but the Partner API will create events, and a rule that
  # only watched updates would be bypassable by whichever path lands first.
  it "refuses a one-step create of a published, large, unlisted event" do
    expect {
      create(:event, creator: owner, organization: organization(verified: false),
                     visibility: "unlisted", capacity: 200)
    }.to raise_error(ActiveRecord::RecordInvalid, /needs a verified organization/)
  end

  # The rule guards transitions, never the resting state — an event that
  # predates it must stay editable, or its organizer couldn't fix a typo.
  it "does not retroactively freeze an existing large unlisted event" do
    # Written past validation on purpose: this is a row from before the rule
    # existed, which is the only way such a row can exist now (see the example
    # above). Building it through the validation would be building a different
    # fixture than the one under test.
    event = create(:event, creator: owner, organization: organization(verified: false),
                           visibility: "public")
    event.update_columns(visibility: "unlisted", capacity: 200)

    patch "/api/v1/events/#{event.id}",
          params: { event: { title: "Corrected Title" } },
          headers: auth_headers(owner), as: :json

    expect(response).to have_http_status(:ok)
    expect(event.reload.title).to eq("Corrected Title")
  end
end
