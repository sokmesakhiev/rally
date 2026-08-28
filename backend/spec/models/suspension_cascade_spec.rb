require "rails_helper"

# organization-identity-tickets.md's Ticket J (#339).
#
# The full matrix in one place, because the cascade's correctness is about how
# the three levels interact, not about any one model in isolation. The part
# that's easy to get wrong is unsuspending: lifting a suspension must restore
# exactly what that suspension took down, and nothing else.
RSpec.describe "Suspension cascade" do
  let(:owner) { create(:user) }
  let(:organization) { create(:organization, owner: owner) }
  let!(:event) { create(:event, :for_organization, presented_by: organization, creator: owner) }

  describe "downward derivation" do
    it "leaves everything unsuspended by default" do
      expect(owner.suspended?).to be(false)
      expect(organization.suspended?).to be(false)
      expect(event.suspended?).to be(false)
    end

    it "cascades from the organization to its events" do
      organization.suspend!(reason: "Reported as fraudulent")

      expect(event.reload.suspended?).to be(true)
    end

    it "cascades from the owner through the organization to its events" do
      owner.suspend!(reason: "Fraud")

      expect(organization.reload.suspended?).to be(true)
      expect(event.reload.suspended?).to be(true)
    end

    # Derived, never written — this is what makes unsuspending correct.
    it "writes nothing to the event when cascading" do
      organization.suspend!(reason: "Reported")

      expect(event.reload.suspended_at).to be_nil
      expect(event.suspension_reason).to be_nil
    end

    it "does not unpublish the event when cascading" do
      organization.suspend!(reason: "Reported")

      expect(event.reload.is_published).to be(true)
    end
  end

  describe "#suspension_source" do
    it "is nil when nothing is suspended" do
      expect(event.suspension_source).to be_nil
    end

    it "is \"event\" for a direct suspension" do
      event.suspend!(reason: "Reported")
      expect(event.suspension_source).to eq("event")
    end

    it "is \"organization\" for an inherited one" do
      organization.suspend!(reason: "Reported")
      expect(event.reload.suspension_source).to eq("organization")
    end

    # Direct wins, because that's the one that survives the organization
    # being unsuspended.
    it "prefers \"event\" when both apply" do
      organization.suspend!(reason: "Org problem")
      event.suspend!(reason: "Its own problem")

      expect(event.reload.suspension_source).to eq("event")
    end
  end

  describe "unsuspending" do
    it "restores the events an organization suspension took down" do
      organization.suspend!(reason: "Reported")
      expect(event.reload.suspended?).to be(true)

      organization.unsuspend!

      expect(event.reload.suspended?).to be(false)
    end

    it "restores everything an owner suspension took down" do
      owner.suspend!
      expect(event.reload.suspended?).to be(true)

      owner.unsuspend!

      expect(organization.reload.suspended?).to be(false)
      expect(event.reload.suspended?).to be(false)
    end

    # The case a provenance column would have had to track, and the reason
    # deriving beats copying.
    it "leaves a directly-suspended event suspended after its organization is restored" do
      event.suspend!(reason: "Its own problem")
      organization.suspend!(reason: "Separate problem")

      organization.unsuspend!

      expect(event.reload.suspended?).to be(true)
      expect(event.suspension_source).to eq("event")
    end

    it "leaves a directly-suspended organization suspended after its owner is restored" do
      organization.suspend!(reason: "Its own problem")
      owner.suspend!

      owner.unsuspend!

      expect(organization.reload.suspended?).to be(true)
      expect(event.reload.suspended?).to be(true)
    end
  end

  # Cascading through admin membership would let one bad actor take down a
  # legitimate organization they happened to volunteer for.
  describe "organizations the suspended user merely administers" do
    let(:club) { create(:organization) }
    let!(:club_event) { create(:event, :for_organization, presented_by: club) }

    before { create(:organization_membership, organization: club, user: owner, role: "admin") }

    it "is untouched when that admin is suspended" do
      owner.suspend!(reason: "Fraud")

      expect(club.reload.suspended?).to be(false)
      expect(club_event.reload.suspended?).to be(false)
    end
  end

  # Replaces the old User#suspend! behaviour, which unpublished events and
  # left them that way after an unsuspend.
  describe "User#suspend! no longer unpublishes" do
    it "leaves is_published alone" do
      expect { owner.suspend! }.not_to change { event.reload.is_published }
    end

    it "still hides the event from the public listing" do
      owner.suspend!

      expect(Event.publicly_visible).not_to include(event)
    end
  end

  # ── The query surface ───────────────────────────────────────────────────────
  describe "Event.publicly_visible" do
    it "includes an ordinary published event" do
      expect(Event.publicly_visible).to include(event)
    end

    it "excludes a directly suspended event" do
      event.suspend!(reason: "Reported")
      expect(Event.publicly_visible).not_to include(event)
    end

    it "excludes an event whose organization is suspended" do
      organization.suspend!(reason: "Reported")
      expect(Event.publicly_visible).not_to include(event)
    end

    it "excludes an event whose organization's owner is suspended" do
      owner.suspend!
      expect(Event.publicly_visible).not_to include(event)
    end

    it "excludes an event whose organization is discarded" do
      organization.discard!
      expect(Event.publicly_visible).not_to include(event)
    end

    it "excludes drafts and discarded events" do
      draft = create(:event, :draft, :for_organization, presented_by: organization)
      discarded = create(:event, :for_organization, presented_by: organization)
      discarded.discard!

      expect(Event.publicly_visible).not_to include(draft, discarded)
    end

    it "brings the event back when the organization is unsuspended" do
      organization.suspend!(reason: "Reported")
      organization.unsuspend!

      expect(Event.publicly_visible).to include(event)
    end

    it "does not return duplicate rows despite joining two tables" do
      expect(Event.publicly_visible.where(id: event.id).count).to eq(1)
    end
  end
end
