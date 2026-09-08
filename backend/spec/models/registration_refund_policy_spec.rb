require "rails_helper"

# The snapshot guarantee, which is the whole point of Ticket D: what a
# participant is owed is fixed by what they were shown at checkout, not by
# whatever the host's policy says later.
RSpec.describe Registration, "refund policy snapshot", type: :model do
  # end_at is set explicitly: the factory defaults it to two weeks out, which
  # would fall before a start_at of thirty days and trip end_after_start.
  let(:event) do
    create(:event, :paid,
      start_at: 30.days.from_now,
      end_at: 31.days.from_now,
      refund_policy_tiers: RefundPolicy.template("standard").to_a)
  end

  describe "on create" do
    it "copies the event's policy onto the registration" do
      registration = create(:registration, event: event)

      expect(registration.refund_policy).to eq(RefundPolicy.template("standard"))
    end

    it "copies nothing when the host has set no policy" do
      registration = create(:registration, event: create(:event, refund_policy_tiers: nil))

      expect(registration.refund_policy).to be_nil
    end

    it "preserves an explicitly non-refundable policy rather than treating it as unset" do
      non_refundable = create(:event, refund_policy_tiers: [])
      registration = create(:registration, event: non_refundable)

      expect(registration.refund_policy).not_to be_nil
      expect(registration.refund_policy).to be_non_refundable
    end

    # Every creation path goes through the model callback, so none of the
    # three call sites has to remember to do this.
    it "applies on a waitlist promotion or guest checkout too, not just the main path" do
      registration = Registration.create!(
        event: event, user: create(:user), status: "confirmed", payment_status: "unpaid"
      )

      expect(registration.refund_policy_tiers).to be_present
    end
  end

  describe "once the host changes their mind" do
    it "does not reduce what an existing participant was promised" do
      registration = create(:registration, event: event)

      event.update!(refund_policy_tiers: [])

      expect(event.reload.refund_policy).to be_non_refundable
      expect(registration.reload.refund_policy).to eq(RefundPolicy.template("standard"))
    end

    it "does apply the new policy to someone registering afterwards" do
      event.update!(refund_policy_tiers: RefundPolicy.template("strict").to_a)

      later = create(:registration, event: event, user: create(:user))

      expect(later.refund_policy).to eq(RefundPolicy.template("strict"))
    end
  end

  describe "#refund_entitlement_cents" do
    # The :paid trait already sets amount_paid_cents to 2500.
    subject(:registration) { create(:registration, :paid, event: event) }

    it "pays in full a month out, under the standard policy" do
      expect(registration.refund_entitlement_cents).to eq(2500)
    end

    it "pays the partial tier a few days out" do
      expect(registration.refund_entitlement_cents(at: event.start_at - 100.hours)).to eq(1250)
    end

    it "pays nothing the day before" do
      expect(registration.refund_entitlement_cents(at: event.start_at - 1.hour)).to eq(0)
    end

    # The distinction Ticket E depends on: nil means "a human decides", 0
    # means "the policy says nothing comes back". Collapsing them would turn
    # every un-policied event into a silent no-refund.
    it "returns nil — not zero — when no policy was in force" do
      unpolicied = create(:registration, :paid, event: create(:event, refund_policy_tiers: nil))

      expect(unpolicied.refund_entitlement_cents).to be_nil
    end

    it "returns zero, not nil, under an explicit non-refundable policy" do
      non_refundable = create(:registration, :paid, event: create(:event, refund_policy_tiers: []))

      expect(non_refundable.refund_entitlement_cents).to eq(0)
    end

    # Tiers are expressed relative to the start, so moving the event moves
    # them with it. Participants hear about date changes separately.
    it "follows the event when the organizer moves the date closer" do
      expect(registration.refund_entitlement_cents).to eq(2500)

      event.update!(start_at: 1.hour.from_now, end_at: 2.hours.from_now)

      expect(registration.reload.refund_entitlement_cents).to eq(0)
    end
  end
end

RSpec.describe Event, "refund policy validation", type: :model do
  it "accepts a well-formed policy" do
    expect(build(:event, refund_policy_tiers: RefundPolicy.template("standard").to_a)).to be_valid
  end

  it "accepts no policy at all" do
    expect(build(:event, refund_policy_tiers: nil)).to be_valid
  end

  it "surfaces the policy's own complaint as a model error" do
    event = build(:event, refund_policy_tiers: [
      { "hours_before" => 48, "refund_percent" => 100 },
      { "hours_before" => 168, "refund_percent" => 50 }
    ])

    expect(event).not_to be_valid
    expect(event.errors[:refund_policy_tiers]).to be_present
  end

  it "does not turn a nil policy into an empty one when assigned through #refund_policy=" do
    event = build(:event)

    event.refund_policy = nil

    expect(event.refund_policy_tiers).to be_nil
  end

  it "accepts a RefundPolicy object through #refund_policy=" do
    event = build(:event)

    event.refund_policy = RefundPolicy.template("flexible")

    expect(event.refund_policy_tiers).to eq([ { "hours_before" => 24, "refund_percent" => 100 } ])
  end
end
