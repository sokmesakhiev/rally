require "rails_helper"

# organization-identity-tickets.md's Ticket E (#334) — a public event must be
# presented by an organization an audience can evaluate.
#
# Kept in its own file rather than folded into event_plan_payments_spec.rb
# because every example here needs the gate switched on, and the rest of that
# suite must keep running with it off (its default, until #336 ships the
# settings UI — see Organization.identity_required_for_publishing?).
RSpec.describe "Organization publish gate", type: :request do
  let(:organizer) { create(:user, :verified) }

  # Same ENV swap/restore shape as spec/services/aba_payway/client_spec.rb.
  around do |example|
    original = ENV.to_hash
    ENV["REQUIRE_ORGANIZATION_IDENTITY"] = "true"
    example.run
  ensure
    ENV.replace(original)
  end

  def incomplete_organization
    create(:organization, owner: organizer, logo_url: nil, description: nil,
                          contact_email: nil, contact_phone: nil)
  end

  def complete_organization
    create(:organization, owner: organizer, logo_url: "https://example.com/logo.png",
                          description: "A running club.", contact_email: "hello@example.com")
  end

  def draft_event_for(organization)
    create(:event, :draft, :for_organization, creator: organizer, presented_by: organization)
  end

  describe "free plan" do
    it "refuses to publish under an incomplete organization" do
      event = draft_event_for(incomplete_organization)

      post "/api/v1/events/#{event.id}/plan_payments",
           params: { plan: "free" }, headers: auth_headers(organizer), as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(json["code"]).to eq("organization_incomplete")
      expect(event.reload.is_published).to be(false)
    end

    it "names the fields still missing" do
      event = draft_event_for(incomplete_organization)

      post "/api/v1/events/#{event.id}/plan_payments",
           params: { plan: "free" }, headers: auth_headers(organizer), as: :json

      expect(json["missing_fields"]).to contain_exactly("logo_url", "description", "contact")
    end

    it "publishes once the organization is complete" do
      event = draft_event_for(complete_organization)

      post "/api/v1/events/#{event.id}/plan_payments",
           params: { plan: "free" }, headers: auth_headers(organizer), as: :json

      expect(response).to have_http_status(:created)
      expect(event.reload.is_published).to be(true)
    end

    it "accepts a phone-only organization" do
      organization = create(:organization, owner: organizer, logo_url: "https://example.com/l.png",
                                           description: "A club.", contact_email: nil,
                                           contact_phone: "012345678")
      event = draft_event_for(organization)

      post "/api/v1/events/#{event.id}/plan_payments",
           params: { plan: "free" }, headers: auth_headers(organizer), as: :json

      expect(response).to have_http_status(:created)
    end
  end

  describe "paid plan" do
    # The point of checking in the controller rather than relying on Event's
    # validation: on the gateway path the publish happens in
    # ProcessAbaPaywayWebhookJob, after ABA has taken the money. Charging an
    # organizer and then refusing to publish is the outcome to avoid.
    it "rejects before any charge is started" do
      event = draft_event_for(incomplete_organization)
      expect_any_instance_of(AbaPayway::Client).not_to receive(:generate_qr)

      expect {
        post "/api/v1/events/#{event.id}/plan_payments",
             params: { plan: "small" }, headers: auth_headers(organizer), as: :json
      }.not_to change(EventPlanPayment, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(json["code"]).to eq("organization_incomplete")
    end
  end

  describe "already-published events" do
    # An event that went live before this rule existed. Published with
    # update_column so it bypasses validation exactly the way history did —
    # creating it published would trip the very gate under test, since the
    # factory sets is_published on create.
    def live_event_under(organization)
      draft_event_for(organization).tap { |e| e.update_column(:is_published, true) }
    end

    # This rule must never retroactively take anything down — it guards the
    # transition into published, not the published state.
    it "leaves a live event under an incomplete organization published" do
      event = live_event_under(incomplete_organization)

      expect(event.reload.is_published).to be(true)
      expect(event).to be_valid
    end

    it "still allows editing a live event under an incomplete organization" do
      event = live_event_under(incomplete_organization)

      patch "/api/v1/events/#{event.id}",
            params: { event: { title: "Renamed While Live" } },
            headers: auth_headers(organizer), as: :json

      expect(response).to have_http_status(:ok)
      expect(event.reload.title).to eq("Renamed While Live")
    end

    # Unpublishing is a move *away* from published, so the gate is irrelevant
    # to it — an organizer must always be able to take their own event down.
    it "allows unpublishing" do
      event = live_event_under(incomplete_organization)

      post "/api/v1/events/#{event.id}/unpublish", headers: auth_headers(organizer), as: :json

      expect(response).to have_http_status(:ok)
      expect(event.reload.is_published).to be(false)
    end
  end

  # The model validation is the backstop: three code paths set is_published,
  # and it sits where all of them pass through.
  describe "the model backstop" do
    it "refuses a direct publish that skips the controller entirely" do
      event = draft_event_for(incomplete_organization)

      event.is_published = true

      expect(event).not_to be_valid
      expect(event.errors[:base].join).to match(/organization/i)
    end

    it "refuses when EventPlanPayment#mark_paid! runs post-payment" do
      event = draft_event_for(incomplete_organization)
      plan_payment = event.event_plan_payments.create!(
        user: organizer, plan: "small", tran_id: "pln#{SecureRandom.alphanumeric(14)}",
        amount_cents: 10_000, currency: "usd", status: "pending", expires_at: 15.minutes.from_now
      )

      expect { plan_payment.mark_paid! }.to raise_error(ActiveRecord::RecordInvalid)
      expect(event.reload.is_published).to be(false)
    end

    it "allows the same publish once the organization is complete" do
      event = draft_event_for(complete_organization)

      event.is_published = true

      expect(event).to be_valid
    end
  end

  describe "when the gate is switched off" do
    around do |example|
      original = ENV.to_hash
      ENV.delete("REQUIRE_ORGANIZATION_IDENTITY")
      example.run
    ensure
      ENV.replace(original)
    end

    # The default until #336 ships the organization settings UI — otherwise
    # every organizer would be blocked from publishing with no way to fix it.
    it "publishes an incomplete organization's event normally" do
      event = draft_event_for(incomplete_organization)

      post "/api/v1/events/#{event.id}/plan_payments",
           params: { plan: "free" }, headers: auth_headers(organizer), as: :json

      expect(response).to have_http_status(:created)
      expect(event.reload.is_published).to be(true)
    end
  end
end
