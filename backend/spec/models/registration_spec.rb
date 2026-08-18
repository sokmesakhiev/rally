require "rails_helper"

RSpec.describe Registration, type: :model do
  subject(:registration) { build(:registration) }

  # ── Associations ─────────────────────────────────────────────────────────────
  describe "associations" do
    it { is_expected.to belong_to(:event) }
    it { is_expected.to belong_to(:user) }
  end

  # ── Validations ──────────────────────────────────────────────────────────────
  describe "validations" do
    it "rejects an invalid status" do
      registration.status = "waitlisted"
      expect(registration).not_to be_valid
    end

    it "rejects an invalid payment_status" do
      registration.payment_status = "pending"
      expect(registration).not_to be_valid
    end

    it "prevents a user from registering for the same event twice" do
      existing = create(:registration)
      duplicate = build(:registration, event: existing.event, user: existing.user)
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:user_id]).to be_present
    end
  end

  # ── Capacity check ───────────────────────────────────────────────────────────
  describe "capacity enforcement" do
    it "allows registration when event has capacity remaining" do
      event = create(:event, capacity: 2)
      expect(build(:registration, event: event)).to be_valid
    end

    it "blocks registration when event is full" do
      event = create(:event, capacity: 1)
      create(:registration, event: event)
      overflow = build(:registration, event: event)
      expect(overflow).not_to be_valid
      expect(overflow.errors[:base]).to include("This event is full")
    end

    it "ignores capacity when event has no limit" do
      event = create(:event, capacity: nil)
      5.times { create(:registration, event: event) }
      expect(build(:registration, event: event)).to be_valid
    end
  end

  # ── Traits ───────────────────────────────────────────────────────────────────
  describe "paid trait" do
    it "sets payment_status to paid" do
      reg = create(:registration, :paid)
      expect(reg.payment_status).to eq("paid")
      expect(reg.amount_paid_cents).to eq(2500)
    end
  end

  # ── Soft-delete ──────────────────────────────────────────────────────────────
  describe "#discard!" do
    it "sets deleted_at and cancels, without destroying the row or its payments" do
      registration = create(:registration, :paid)
      payment = create(:payment, :approved, registration: registration)

      expect { registration.discard! }.not_to change(Registration, :count)
      expect(registration.discarded?).to be(true)
      expect(registration.status).to eq("cancelled")
      expect(Registration.kept).not_to include(registration)
      expect(Payment.exists?(payment.id)).to be(true)
    end

    it "frees the capacity slot, same as .active already excludes it" do
      event = create(:event, capacity: 1)
      registration = create(:registration, event: event)
      expect(event.reload).to be_full

      registration.discard!

      expect(event.reload).not_to be_full
    end
  end

  # ── Check-in ─────────────────────────────────────────────────────────────────
  describe "#checked_in?" do
    it "is false when checked_in_at is blank" do
      expect(build(:registration, checked_in_at: nil).checked_in?).to be(false)
    end

    it "is true once checked_in_at is set" do
      expect(build(:registration, checked_in_at: Time.current).checked_in?).to be(true)
    end
  end
end
