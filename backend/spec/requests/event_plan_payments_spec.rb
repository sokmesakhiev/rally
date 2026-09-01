require "rails_helper"

RSpec.describe "Event plan payments API", type: :request do
  let(:organizer) { create(:user) }

  let(:generate_qr_response) do
    {
      status: { code: "0", message: "Success", trace_id: "trace-1" },
      qrString: "00020101...",
      abapay_deeplink: "abamobilebank://ababank.com?type=payway&qrcode=..."
    }
  end

  describe "POST /api/v1/events/:event_id/plan_payments" do
    context "when the event's types add up to more than the chosen plan allows" do
      let!(:event) { create(:event, :draft, creator: organizer) }

      before do
        event.event_types.create!(name: "5K", capacity: 100, position: 0)
        event.event_types.create!(name: "10K", capacity: 150, position: 1)
      end

      it "rejects the small plan (200) without charging or creating a plan payment" do
        expect_any_instance_of(AbaPayway::Client).not_to receive(:generate_qr)

        post "/api/v1/events/#{event.id}/plan_payments",
             params: { plan: "small" },
             headers: auth_headers(organizer),
             as: :json

        expect(response).to have_http_status(:unprocessable_content)
        expect(json["code"]).to eq("plan_capacity_too_low")
        expect(json["error"]).to include("Small plan allows up to 200")
        expect(json["error"]).to include("250")
        expect(event.reload).not_to be_is_published
        expect(event.event_plan_payments).to be_empty
      end

      it "rejects even the free tier without publishing" do
        post "/api/v1/events/#{event.id}/plan_payments",
             params: { plan: "free" },
             headers: auth_headers(organizer),
             as: :json

        expect(response).to have_http_status(:unprocessable_content)
        expect(json["code"]).to eq("plan_capacity_too_low")
        expect(event.reload).not_to be_is_published
      end

      it "accepts a plan whose capacity covers the combined type limits" do
        allow_any_instance_of(AbaPayway::Client).to receive(:generate_qr).and_return(generate_qr_response)

        post "/api/v1/events/#{event.id}/plan_payments",
             params: { plan: "medium" },
             headers: auth_headers(organizer),
             as: :json

        expect(response).to have_http_status(:created)
        expect(json["plan_payment"]["status"]).to eq("pending")
      end

      it "rejects re-publishing under an already-paid plan that no longer fits" do
        # Simulates: organizer published under "small" (200) back when their
        # types fit, then unpublished and added more types that now total
        # 250. update_columns bypasses Event's own validation here since
        # we're seeding prior state, not performing the action under test.
        event.update_columns(plan: "small", capacity: 200)

        post "/api/v1/events/#{event.id}/plan_payments",
             params: { plan: "small" },
             headers: auth_headers(organizer),
             as: :json

        expect(response).to have_http_status(:unprocessable_content)
        expect(json["code"]).to eq("plan_capacity_too_low")
        expect(event.reload).not_to be_is_published
      end
    end

    context "when the event's types fit comfortably within the plan" do
      let!(:event) { create(:event, :draft, creator: organizer) }

      it "publishes the free tier immediately" do
        event.event_types.create!(name: "5K", capacity: 10, position: 0)

        post "/api/v1/events/#{event.id}/plan_payments",
             params: { plan: "free" },
             headers: auth_headers(organizer),
             as: :json

        expect(response).to have_http_status(:created)
        expect(event.reload).to be_is_published
      end
    end

    # ── Changing plan on an already-published event ──────────────────────────
    context "when the event is already published" do
      # Seeds the paid history a real "small" event would already have from
      # its initial publish — #amount_already_paid_cents sums paid
      # EventPlanPayment rows, so a published event with no such row would
      # (incorrectly, for these tests) look like it had paid nothing yet.
      let!(:event) do
        create(:event, creator: organizer, is_published: true, plan: "small", capacity: 200).tap do |e|
          e.event_plan_payments.create!(
            user: organizer, plan: "small", tran_id: "seed-#{e.id}",
            amount_cents: Event::PLANS["small"][:price_cents], currency: "usd",
            status: "paid", paid_at: 1.day.ago
          )
        end
      end

      it "rejects requesting the same plan again" do
        post "/api/v1/events/#{event.id}/plan_payments",
             params: { plan: "small" },
             headers: auth_headers(organizer),
             as: :json

        expect(response).to have_http_status(:unprocessable_content)
        expect(json["error"]).to include("already on this plan")
      end

      it "charges only the prorated difference when upgrading" do
        allow_any_instance_of(AbaPayway::Client).to receive(:generate_qr).and_return(generate_qr_response)
        expected_delta = Event::PLANS["medium"][:price_cents] - Event::PLANS["small"][:price_cents]

        post "/api/v1/events/#{event.id}/plan_payments",
             params: { plan: "medium" },
             headers: auth_headers(organizer),
             as: :json

        expect(response).to have_http_status(:created)
        expect(json["plan_payment"]["amount_cents"]).to eq(expected_delta)
        expect(json["plan_payment"]["status"]).to eq("pending")
        # Not applied until ABA confirms — same as the initial-publish flow.
        expect(event.reload.plan).to eq("small")
      end

      it "downgrades immediately with no charge and no refund" do
        expect_any_instance_of(AbaPayway::Client).not_to receive(:generate_qr)

        post "/api/v1/events/#{event.id}/plan_payments",
             params: { plan: "free" },
             headers: auth_headers(organizer),
             as: :json

        expect(response).to have_http_status(:created)
        expect(json["plan_payment"]["amount_cents"]).to eq(0)
        expect(json["plan_payment"]["status"]).to eq("paid")
        event.reload
        expect(event.plan).to eq("free")
        expect(event.capacity).to eq(Event::PLANS["free"][:capacity])
      end

      it "doesn't re-charge for a plan already covered by the high-water mark" do
        # Paid for "large" once, downgraded to "small" (no refund — the
        # organizer's total paid-in stays at large's price), now moving back
        # up to "medium", which large already covers.
        event.event_plan_payments.create!(
          user: organizer, plan: "large", tran_id: "seed-large-#{event.id}",
          amount_cents: Event::PLANS["large"][:price_cents] - Event::PLANS["small"][:price_cents],
          currency: "usd", status: "paid", paid_at: 12.hours.ago
        )
        event.update_columns(plan: "large", capacity: Event::PLANS["large"][:capacity])

        expect_any_instance_of(AbaPayway::Client).not_to receive(:generate_qr)

        post "/api/v1/events/#{event.id}/plan_payments",
             params: { plan: "medium" },
             headers: auth_headers(organizer),
             as: :json

        expect(response).to have_http_status(:created)
        expect(json["plan_payment"]["amount_cents"]).to eq(0)
        expect(event.reload.plan).to eq("medium")
      end

      it "rejects downgrading below the number of people already registered" do
        create_list(:registration, 21, event: event) # small's cap is 200; free's is 20

        post "/api/v1/events/#{event.id}/plan_payments",
             params: { plan: "free" },
             headers: auth_headers(organizer),
             as: :json

        expect(response).to have_http_status(:unprocessable_content)
        expect(json["code"]).to eq("plan_capacity_too_low")
        expect(json["error"]).to include("already registered")
        expect(event.reload.plan).to eq("small")
      end

      it "blocks starting a new plan change while an earlier one is still pending" do
        allow_any_instance_of(AbaPayway::Client).to receive(:generate_qr).and_return(generate_qr_response)
        post "/api/v1/events/#{event.id}/plan_payments", params: { plan: "medium" },
             headers: auth_headers(organizer), as: :json
        expect(response).to have_http_status(:created)

        post "/api/v1/events/#{event.id}/plan_payments", params: { plan: "large" },
             headers: auth_headers(organizer), as: :json

        expect(response).to have_http_status(:unprocessable_content)
        expect(json["code"]).to eq("plan_change_pending")
      end

      it "allows a new plan change once the earlier pending one has expired" do
        event.event_plan_payments.create!(
          user: organizer, plan: "medium", tran_id: "expired-#{event.id}",
          amount_cents: 1, currency: "usd", status: "pending",
          expires_at: 1.minute.ago
        )
        allow_any_instance_of(AbaPayway::Client).to receive(:generate_qr).and_return(generate_qr_response)

        post "/api/v1/events/#{event.id}/plan_payments",
             params: { plan: "medium" },
             headers: auth_headers(organizer),
             as: :json

        expect(response).to have_http_status(:created)
      end
    end

    # Issue #278 — plan payments stay owner-only even for Manager: they
    # charge the owner's own card, so a Manager (who runs the event day to
    # day but doesn't hold the purse) may not initiate one.
    context "when the caller is a Manager member, not the owner" do
      let!(:event) { create(:event, :draft, creator: organizer) }

      it "returns 404, the same as any other non-owner" do
        manager = create(:user)
        create(:event_membership, event: event, user: manager, role: "manager")

        post "/api/v1/events/#{event.id}/plan_payments",
             params: { plan: "free" },
             headers: auth_headers(manager),
             as: :json

        expect(response).to have_http_status(:not_found)
      end
    end
  end
end
