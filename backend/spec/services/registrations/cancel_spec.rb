require "rails_helper"

RSpec.describe Registrations::Cancel do
  let(:participant) { create(:user) }
  let(:gateway_success_response) { { status: { code: "00", message: "success" } } }

  # 100% up to 7 days out, 50% up to 48 hours out, nothing after.
  def event_with(policy_tiers, start_at: 30.days.from_now)
    create(:event, :paid,
      start_at: start_at,
      end_at: start_at + 1.day,
      refund_policy_tiers: policy_tiers)
  end

  def paid_registration(event, cents: 2500)
    registration = create(:registration, :paid, event: event, user: participant)
    registration.update!(amount_paid_cents: cents)
    create(:payment, :approved, registration: registration, amount_cents: cents)
    registration
  end

  def cancel(registration, **kwargs)
    described_class.new(registration: registration, initiated_by: participant, **kwargs).call
  end

  before do
    allow_any_instance_of(AbaPayway::Client).to receive(:refund).and_return(gateway_success_response)
  end

  describe "when the policy entitles a full refund" do
    let(:event) { event_with(RefundPolicy.template("standard").to_a) }

    it "refunds everything and cancels the registration" do
      registration = paid_registration(event)

      result = cancel(registration)

      expect(result.status).to eq(:cancelled_with_refund)
      expect(result.refund_cents).to eq(2500)
      expect(registration.reload.status).to eq("cancelled")
    end

    it "takes the amount from the policy rather than asking anyone" do
      registration = paid_registration(event)

      expect_any_instance_of(AbaPayway::Client)
        .to receive(:refund).with(hash_including(amount_cents: 2500))
        .and_return(gateway_success_response)

      cancel(registration)
    end
  end

  describe "when the policy entitles a partial refund" do
    let(:event) { event_with(RefundPolicy.template("standard").to_a) }

    # The case IssueRefund alone gets wrong: it only cancels a registration
    # when a refund exhausts its payment, but a participant giving up their
    # spot for 50% back has still given up their spot.
    it "cancels the registration even though the payment isn't exhausted" do
      registration = paid_registration(event)

      result = cancel(registration, at: event.start_at - 100.hours)

      expect(result.status).to eq(:cancelled_with_refund)
      expect(result.refund_cents).to eq(1250)
      expect(registration.reload.status).to eq("cancelled")
      expect(registration.payment_status).to eq("partially_refunded")
    end

    it "frees the spot exactly once" do
      other = create(:user)
      registration = paid_registration(event)
      # Cap the event *before* anyone joins the waitlist: WaitlistEntry
      # refuses to queue for an event that isn't full yet, which is the
      # right rule — you'd just register instead.
      event.update!(capacity: 1)
      create(:waitlist_entry, event: event, user: other)

      cancel(registration, at: event.start_at - 100.hours)

      expect(event.reload.registrations.active.count).to eq(1)
    end
  end

  describe "when the policy gives nothing back" do
    it "still cancels, and reports a zero refund rather than failing" do
      registration = paid_registration(event_with(RefundPolicy.template("standard").to_a))

      result = cancel(registration, at: registration.event.start_at - 1.hour)

      expect(result.status).to eq(:cancelled)
      expect(result.refund_cents).to eq(0)
      expect(registration.reload.status).to eq("cancelled")
    end

    it "does not call the gateway at all" do
      registration = paid_registration(event_with([]))

      expect_any_instance_of(AbaPayway::Client).not_to receive(:refund)

      expect(cancel(registration).status).to eq(:cancelled)
    end
  end

  describe "when the host set no policy" do
    let(:event) { event_with(nil) }

    # The nil/[] distinction earning its keep: silently cancelling here would
    # cost the participant money the organizer might well have returned.
    it "refuses a paid registration and points at the organizer" do
      registration = paid_registration(event)

      result = cancel(registration)

      expect(result.status).to eq(:requires_organizer)
      expect(registration.reload.status).to eq("confirmed")
    end

    it "still lets an unpaid registration go, since there's nothing at stake" do
      registration = create(:registration, event: event, user: participant)

      result = cancel(registration)

      expect(result.status).to eq(:cancelled)
      expect(registration.reload.status).to eq("cancelled")
    end
  end

  describe "guards" do
    it "refuses a registration that's already cancelled" do
      registration = paid_registration(event_with(RefundPolicy.template("standard").to_a))
      registration.update!(status: "cancelled")

      expect(cancel(registration).status).to eq(:already_cancelled)
    end

    it "never refunds more than the payments can still give back" do
      event = event_with(RefundPolicy.template("standard").to_a)
      registration = create(:registration, :paid, event: event, user: participant)
      registration.update!(amount_paid_cents: 2500)
      # Entitlement says 2500, but half has already gone back.
      create(:payment, :approved, registration: registration,
        amount_cents: 2500, refunded_amount_cents: 1250, status: "partially_refunded")

      result = cancel(registration)

      expect(result.refund_cents).to eq(1250)
    end

    it "reports a gateway failure without pretending the spot was given up" do
      allow_any_instance_of(AbaPayway::Client)
        .to receive(:refund).and_raise(AbaPayway::RequestError, "timeout")
      registration = paid_registration(event_with(RefundPolicy.template("standard").to_a))

      result = cancel(registration)

      expect(result.status).to eq(:refund_failed)
      expect(result.refund_cents).to eq(0)
      expect(registration.reload.status).to eq("confirmed")
    end
  end
end
