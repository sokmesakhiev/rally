require "rails_helper"

RSpec.describe EventInvitation, type: :model do
  let(:owner) { create(:user) }
  let(:event) { create(:event, creator: owner) }

  describe "associations" do
    it { is_expected.to belong_to(:event) }
    it { is_expected.to belong_to(:invited_by).class_name("User") }
  end

  describe "validations" do
    subject { build(:event_invitation) }

    it { is_expected.to validate_presence_of(:email) }
    it { is_expected.to validate_presence_of(:role) }
    it { is_expected.to validate_inclusion_of(:role).in_array(EventMembership::ROLES) }

    it "rejects a malformed email" do
      expect(build(:event_invitation, email: "not-an-email")).not_to be_valid
    end

    it "downcases and strips the email" do
      invitation = create(:event_invitation, email: "  Volunteer@Example.COM ")

      expect(invitation.email).to eq("volunteer@example.com")
    end

    it "allows only one live invitation per email per event" do
      create(:event_invitation, event: event, email: "v@example.com")

      duplicate = build(:event_invitation, event: event, email: "v@example.com")

      # Enforced by a partial unique index rather than a model validation —
      # "live" depends on accepted_at/revoked_at, which a uniqueness
      # validation can't express. Asserting the DB-level failure is the point.
      expect { duplicate.save! }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "allows re-inviting the same email once the earlier invitation is revoked" do
      first = create(:event_invitation, event: event, email: "v@example.com")
      first.revoke!

      expect(build(:event_invitation, event: event, email: "v@example.com")).to be_valid
    end
  end

  describe "defaults on create" do
    it "generates a unique token and a 14-day expiry" do
      invitation = create(:event_invitation, event: event)

      expect(invitation.token).to be_present
      expect(invitation.expires_at).to be_within(1.minute).of(described_class::EXPIRY.from_now)
    end

    it "does not reuse tokens" do
      tokens = Array.new(3) { create(:event_invitation, event: event).token }

      expect(tokens.uniq.size).to eq(3)
    end
  end

  describe "state predicates" do
    it "is pending when freshly created" do
      invitation = create(:event_invitation, event: event)

      expect(invitation).to be_pending
      expect(invitation).not_to be_accepted
      expect(invitation).not_to be_revoked
      expect(invitation).not_to be_expired
    end

    it "is no longer pending once accepted" do
      invitation = create(:event_invitation, :accepted, event: event)

      expect(invitation).to be_accepted
      expect(invitation).not_to be_pending
    end

    it "is no longer pending once revoked" do
      invitation = create(:event_invitation, :revoked, event: event)

      expect(invitation).to be_revoked
      expect(invitation).not_to be_pending
    end

    it "is no longer pending once expired" do
      invitation = create(:event_invitation, :expired, event: event)

      expect(invitation).to be_expired
      expect(invitation).not_to be_pending
    end
  end

  describe "#accept! / #revoke!" do
    it "stamps accepted_at" do
      invitation = create(:event_invitation, event: event)

      expect { invitation.accept! }.to change { invitation.reload.accepted_at }.from(nil)
    end

    it "stamps revoked_at" do
      invitation = create(:event_invitation, event: event)

      expect { invitation.revoke! }.to change { invitation.reload.revoked_at }.from(nil)
    end
  end

  describe ".find_by_valid_token" do
    it "returns the invitation for a live token" do
      invitation = create(:event_invitation, event: event)

      expect(described_class.find_by_valid_token(invitation.token)).to eq(invitation)
    end

    it "returns nil for a blank token" do
      expect(described_class.find_by_valid_token(nil)).to be_nil
      expect(described_class.find_by_valid_token("")).to be_nil
    end

    it "returns nil for an unknown token" do
      expect(described_class.find_by_valid_token("nope")).to be_nil
    end

    it "returns nil once accepted" do
      invitation = create(:event_invitation, :accepted, event: event)

      expect(described_class.find_by_valid_token(invitation.token)).to be_nil
    end

    it "returns nil once revoked" do
      invitation = create(:event_invitation, :revoked, event: event)

      expect(described_class.find_by_valid_token(invitation.token)).to be_nil
    end

    it "returns nil once expired" do
      invitation = create(:event_invitation, :expired, event: event)

      expect(described_class.find_by_valid_token(invitation.token)).to be_nil
    end
  end

  describe ".pending" do
    it "excludes accepted, revoked, and expired invitations" do
      live = create(:event_invitation, event: event)
      create(:event_invitation, :accepted, event: event)
      create(:event_invitation, :revoked, event: event)
      create(:event_invitation, :expired, event: event)

      expect(event.event_invitations.pending.to_a).to eq([ live ])
    end
  end

  describe "Event#discard!" do
    it "leaves invitations intact, same reasoning as memberships" do
      create(:event_invitation, event: event)

      expect { event.discard! }.not_to change(described_class, :count)
    end
  end
end
