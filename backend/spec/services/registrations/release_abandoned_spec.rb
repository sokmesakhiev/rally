require "rails_helper"

RSpec.describe Registrations::ReleaseAbandoned do
  let(:event) { create(:event, :paid, capacity: 10) }

  # `payment_state` is the Payment row's own status, not the registration's —
  # the registration is always "unpaid" here, that's the point.
  def abandoned_registration(registered_at: 3.hours.ago, payment_at: nil, payment_state: "pending")
    registration = create(:registration, event: event, payment_status: "unpaid")
    registration.update_columns(created_at: registered_at)
    if payment_at
      payment = create(:payment, registration: registration, status: payment_state)
      payment.update_columns(created_at: payment_at)
    end
    registration
  end

  describe "what it releases" do
    it "releases a registration whose payment attempt expired long ago" do
      registration = abandoned_registration(payment_at: 2.hours.ago)

      expect(described_class.call.released).to eq(1)
      expect(registration.reload).to be_discarded
      expect(registration.status).to eq("cancelled")
    end

    it "releases one where the payment screen was never opened" do
      registration = abandoned_registration(registered_at: 3.hours.ago)

      described_class.call

      expect(registration.reload).to be_discarded
    end

    it "frees the capacity slot" do
      abandoned_registration(payment_at: 2.hours.ago)
      expect(event.reload.registrations.active.count).to eq(1)

      described_class.call

      expect(event.reload.registrations.active.count).to eq(0)
    end
  end

  describe "what it leaves alone" do
    # The guard that matters most. Free registrations are created with
    # payment_status "paid" (RegistrationsController#create,
    # Waitlists::PromoteNext), so they can't match — but if that default ever
    # changed, this job would quietly cancel every free registration on the
    # platform. This spec is the tripwire.
    it "never touches a free registration" do
      free_event = create(:event, price_cents: 0, capacity: 10)
      registration = create(:registration, event: free_event, payment_status: "paid")
      registration.update_columns(created_at: 1.year.ago)

      expect(described_class.call.released).to eq(0)
      expect(registration.reload).not_to be_discarded
    end

    it "leaves a paid registration alone" do
      registration = create(:registration, :paid, event: event)
      registration.update_columns(created_at: 1.year.ago)

      described_class.call

      expect(registration.reload).not_to be_discarded
    end

    it "leaves a registration still inside the grace period" do
      registration = abandoned_registration(payment_at: 10.minutes.ago)

      expect(described_class.call.released).to eq(0)
      expect(registration.reload).not_to be_discarded
    end

    # A participant who registered hours ago but opened the payment screen a
    # few minutes ago hasn't abandoned anything — the clock runs from the most
    # recent attempt, not from the registration.
    it "leaves an old registration whose latest payment attempt is recent" do
      registration = abandoned_registration(registered_at: 2.days.ago, payment_at: 5.minutes.ago)

      expect(described_class.call.released).to eq(0)
      expect(registration.reload).not_to be_discarded
    end

    # Every status that means money moved, not just "approved" — a refunded
    # payment still proves this wasn't an abandoned checkout.
    described_class::SETTLED_PAYMENT_STATUSES.each do |settled|
      it "leaves one with a #{settled} payment, even if payment_status lags behind" do
        registration = abandoned_registration(payment_at: 3.hours.ago, payment_state: settled)

        expect(described_class.call.released).to eq(0)
        expect(registration.reload).not_to be_discarded
      end
    end

    it "does not re-process something already released" do
      registration = abandoned_registration(payment_at: 3.hours.ago)
      described_class.call

      expect(described_class.call.released).to eq(0)
      expect(registration.reload).to be_discarded
    end
  end

  # The window between the candidate query and the discard is real: ABA's
  # webhook can land in it. Cancelling a registration somebody actually paid
  # for is the worst thing this job could do.
  describe "when a payment lands mid-sweep" do
    it "does not cancel a registration that got paid after the query ran" do
      registration = abandoned_registration(payment_at: 3.hours.ago)

      allow_any_instance_of(Registration).to receive(:with_lock).and_wrap_original do |method, &block|
        registration.update_columns(payment_status: "paid")
        method.call(&block)
      end

      expect(described_class.call.released).to eq(0)
      expect(registration.reload).not_to be_discarded
    end

    # Exercises the second guard specifically. The payment_status column is
    # left untouched, so only the settled-payment check can catch this — which
    # is the case that slipped through when the re-check used a narrower status
    # list than the candidate query.
    it "does not cancel one whose payment settles mid-sweep without payment_status catching up" do
      registration = abandoned_registration(payment_at: 3.hours.ago)

      allow_any_instance_of(Registration).to receive(:with_lock).and_wrap_original do |method, &block|
        registration.payments.first.update_columns(status: "refunded")
        method.call(&block)
      end

      expect(described_class.call.released).to eq(0)
      expect(registration.reload).not_to be_discarded
    end
  end

  describe "the freed slot" do
    it "goes to whoever is next on the waitlist" do
      full_event = create(:event, :paid, capacity: 1)
      abandoned = create(:registration, event: full_event, payment_status: "unpaid")
      abandoned.update_columns(created_at: 3.hours.ago)
      waiting = create(:user)
      create(:waitlist_entry, event: full_event, user: waiting)

      result = described_class.call

      expect(result.promoted).to eq(1)
      expect(full_event.reload.registrations.active.map(&:user)).to eq([ waiting ])
    end

    # Three slots freed on one event should walk the waitlist once and fill all
    # three, not run the whole promotion pass three times.
    it "runs the waitlist pass once per event, not once per registration" do
      3.times do
        create(:registration, event: event, payment_status: "unpaid")
          .update_columns(created_at: 3.hours.ago)
      end

      allow(Waitlists::PromoteNext).to receive(:call).and_return([])

      expect(described_class.call.released).to eq(3)
      expect(Waitlists::PromoteNext).to have_received(:call).once
    end
  end

  describe "after a sweep" do
    # The reason this ticket also made the unique index partial. Without that,
    # releasing an abandoned registration would lock the participant out of the
    # event forever, with nothing in the UI to explain it.
    it "lets the same participant register again" do
      registration = abandoned_registration(payment_at: 3.hours.ago)
      participant = registration.user
      described_class.call

      retry_registration = build(:registration, event: event, user: participant)

      expect(retry_registration).to be_valid
      expect { retry_registration.save! }.not_to raise_error
    end
  end

  describe "the grace period" do
    it "is an hour by default — comfortably past the 15-minute KHQR lifetime" do
      expect(described_class::GRACE_PERIOD).to eq(1.hour)
      expect(described_class::GRACE_PERIOD).to be > Payments::CreatePayment::PAYMENT_LIFETIME_MINUTES.minutes
    end

    it "is overridable, so a caller can sweep more or less aggressively" do
      registration = abandoned_registration(payment_at: 30.minutes.ago)

      expect(described_class.call(grace_period: 5.minutes).released).to eq(1)
      expect(registration.reload).to be_discarded
    end
  end
end
