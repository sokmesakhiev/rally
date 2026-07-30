require "rails_helper"

RSpec.describe EventPlanPayment do
  let(:event) { create(:event, :draft) }

  def build_plan_payment(**attrs)
    event.event_plan_payments.build({
      user: event.creator,
      plan: "small",
      tran_id: "pln#{SecureRandom.alphanumeric(10)}",
      amount_cents: 10_000,
      currency: "usd",
      status: "pending",
      expires_at: 15.minutes.from_now
    }.merge(attrs))
  end

  describe "validations" do
    it { expect(build_plan_payment).to be_valid }

    it "only accepts a plan that exists in Event::PLANS" do
      Event::PLANS.each_key do |plan|
        expect(build_plan_payment(plan: plan)).to be_valid
      end

      expect(build_plan_payment(plan: "enormous")).not_to be_valid
    end

    it "requires a tran_id and enforces uniqueness" do
      expect(build_plan_payment(tran_id: nil)).not_to be_valid

      build_plan_payment(tran_id: "pln-duplicate").save!
      expect(build_plan_payment(tran_id: "pln-duplicate")).not_to be_valid
    end

    it "only accepts a known status" do
      EventPlanPayment::STATUSES.each do |status|
        expect(build_plan_payment(status: status)).to be_valid
      end

      expect(build_plan_payment(status: "approved")).not_to be_valid
    end

    it "allows a zero amount (the free tier) but not a negative one" do
      expect(build_plan_payment(plan: "free", amount_cents: 0)).to be_valid
      expect(build_plan_payment(amount_cents: -1)).not_to be_valid
    end

    it "defaults provider to aba_payway" do
      expect(build_plan_payment.tap(&:save!).provider).to eq("aba_payway")
    end
  end

  describe "#expired?" do
    it "is false when expires_at is in the future or nil" do
      expect(build_plan_payment(expires_at: 5.minutes.from_now)).not_to be_expired
      expect(build_plan_payment(expires_at: nil)).not_to be_expired
    end

    it "is true once expires_at has passed" do
      expect(build_plan_payment(expires_at: 1.minute.ago)).to be_expired
    end
  end

  describe "#formatted_amount" do
    it "renders USD with two decimal places" do
      expect(build_plan_payment(amount_cents: 10_000, currency: "usd").formatted_amount).to eq("100.00")
    end

    it "renders KHR with no decimal places, since ABA expects riel as whole units" do
      expect(build_plan_payment(amount_cents: 10_000, currency: "khr").formatted_amount).to eq("100")
    end

    it "is case-insensitive about the currency code" do
      expect(build_plan_payment(amount_cents: 10_000, currency: "KHR").formatted_amount).to eq("100")
    end
  end

  describe "#mark_paid!" do
    it "marks itself paid and publishes the event under the paid plan's capacity" do
      plan_payment = build_plan_payment(plan: "small")
      plan_payment.save!

      plan_payment.mark_paid!

      expect(plan_payment.reload.status).to eq("paid")
      expect(plan_payment.paid_at).to be_present

      event.reload
      expect(event.is_published).to be(true)
      expect(event.plan).to eq("small")
      expect(event.capacity).to eq(Event::PLANS.fetch("small")[:capacity])
    end

    it "stores the gateway response when given one" do
      plan_payment = build_plan_payment
      plan_payment.save!

      plan_payment.mark_paid!(raw_response: { "status" => { "code" => "00" } })

      expect(plan_payment.reload.raw_response).to eq({ "status" => { "code" => "00" } })
    end

    it "rolls back entirely if publishing the event fails" do
      # mark_paid! wraps both updates in a transaction. If the event can't be
      # published — e.g. its event types add up to more than the plan allows,
      # which Event#capacity_covers_event_types rejects — the payment must NOT
      # be left marked paid, or an organizer is charged for a plan that never
      # took effect.
      event.event_types.create!(name: "5K", capacity: 150, position: 0)
      event.event_types.create!(name: "10K", capacity: 150, position: 1)
      plan_payment = build_plan_payment(plan: "small") # capacity 200 < 300 combined
      plan_payment.save!

      expect { plan_payment.mark_paid! }.to raise_error(ActiveRecord::RecordInvalid)

      expect(plan_payment.reload.status).to eq("pending")
      expect(event.reload.is_published).to be(false)
    end
  end

  describe "scopes and predicates" do
    it "#pending? and .pending track the pending status" do
      pending_payment = build_plan_payment(status: "pending")
      pending_payment.save!
      paid_payment = build_plan_payment(status: "paid")
      paid_payment.save!

      expect(pending_payment).to be_pending
      expect(paid_payment).not_to be_pending
      expect(paid_payment).to be_paid
      expect(EventPlanPayment.pending).to include(pending_payment)
      expect(EventPlanPayment.pending).not_to include(paid_payment)
    end
  end
end
