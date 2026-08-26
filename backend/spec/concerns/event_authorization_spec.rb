require "rails_helper"

# Unit spec for the concern itself. The exhaustive role x capability matrix
# lives here rather than duplicated per-controller; the request specs
# (events_spec, registrations_spec, refunds_spec, results_spec,
# waitlist_entries_spec, survey_responses_spec, event_plan_payments_spec) only
# need to prove each endpoint actually calls through to this concern with the
# right capability — not re-derive the whole matrix themselves.
RSpec.describe EventAuthorization do
  # Minimal host that satisfies the concern's contract: it needs
  # #current_user and #render. Deliberately not a real controller — this is
  # about the decision logic, not Rails plumbing.
  let(:host_class) do
    Class.new do
      include EventAuthorization
      attr_accessor :current_user, :rendered

      def render(payload)
        @rendered = payload
      end
    end
  end

  let(:host) { host_class.new }
  let(:owner) { create(:user) }
  let(:stranger) { create(:user) }
  let(:event) { create(:event, creator: owner) }

  describe "#event_role_for" do
    it "returns :owner for the event's creator" do
      host.current_user = owner
      expect(host.event_role_for(event)).to eq(:owner)
    end

    it "returns nil for someone with no relationship to the event" do
      host.current_user = stranger
      expect(host.event_role_for(event)).to be_nil
    end

    it "returns nil when there is no signed-in user" do
      host.current_user = nil
      expect(host.event_role_for(event)).to be_nil
    end

    it "returns nil when the event is nil" do
      host.current_user = owner
      expect(host.event_role_for(nil)).to be_nil
    end

    it "returns the member's role as a symbol" do
      member = create(:user)
      create(:event_membership, event: event, user: member, role: "check_in")
      host.current_user = member

      expect(host.event_role_for(event)).to eq(:check_in)
    end

    it "prefers :owner over any membership row the creator might also hold" do
      create(:event_membership, event: event, user: owner, role: "viewer")
      host.current_user = owner

      expect(host.event_role_for(event)).to eq(:owner)
    end

    it "does not leak a role across events" do
      member = create(:user)
      create(:event_membership, event: event, user: member, role: "manager")
      other_event = create(:event)
      host.current_user = member

      expect(host.event_role_for(other_event)).to be_nil
    end
  end

  describe "#event_permits?" do
    it "allows the owner every capability" do
      host.current_user = owner

      described_class::CAPABILITIES.each_key do |capability|
        expect(host.event_permits?(event, capability)).to be(true),
          "expected owner to be permitted :#{capability}"
      end
    end

    it "denies a stranger every capability" do
      host.current_user = stranger

      described_class::CAPABILITIES.each_key do |capability|
        expect(host.event_permits?(event, capability)).to be(false),
          "expected stranger to be denied :#{capability}"
      end
    end

    # The full role x capability matrix, both allow and deny, driven off the
    # real CAPABILITIES data rather than a second hardcoded copy of it — this
    # is what actually exercises "every capability, every role" per issue
    # #278's acceptance criteria; the more specific examples below pin the
    # policy calls (which capabilities each role does/doesn't get) that this
    # data-driven pass alone wouldn't make legible on its own.
    it "grants each member exactly the capabilities their role has in CAPABILITIES" do
      EventMembership::ROLES.each do |role|
        member = create(:user)
        create(:event_membership, event: event, user: member, role: role)
        host.current_user = member

        described_class::CAPABILITIES.each do |capability, allowed_roles|
          expected = allowed_roles.include?(role.to_sym)
          expect(host.event_permits?(event, capability)).to be(expected),
            "expected #{role} to be #{expected ? 'allowed' : 'denied'} :#{capability}"
        end
      end
    end

    it "grants Manager everything except plan payments, unpublish, delete, and member management" do
      manager = create(:user)
      create(:event_membership, event: event, user: manager, role: "manager")
      host.current_user = manager

      owner_only = %i[manage_plan unpublish_event delete_event manage_members]
      (described_class::CAPABILITIES.keys - owner_only).each do |capability|
        expect(host.event_permits?(event, capability)).to be(true),
          "expected manager to be allowed :#{capability}"
      end
      owner_only.each do |capability|
        expect(host.event_permits?(event, capability)).to be(false),
          "expected manager to be denied :#{capability}"
      end
    end

    it "grants Check-in only viewing plus check-in, not write actions or exports" do
      check_in_staff = create(:user)
      create(:event_membership, event: event, user: check_in_staff, role: "check_in")
      host.current_user = check_in_staff

      allowed = %i[view_event view_participants check_in]
      allowed.each do |capability|
        expect(host.event_permits?(event, capability)).to be(true),
          "expected check_in to be allowed :#{capability}"
      end
      (described_class::CAPABILITIES.keys - allowed).each do |capability|
        expect(host.event_permits?(event, capability)).to be(false),
          "expected check_in to be denied :#{capability}"
      end
    end

    it "grants Viewer only read capabilities, never check-in or any write action" do
      viewer = create(:user)
      create(:event_membership, event: event, user: viewer, role: "viewer")
      host.current_user = viewer

      allowed = %i[view_event view_participants view_waitlist view_survey_responses view_activity]
      allowed.each do |capability|
        expect(host.event_permits?(event, capability)).to be(true),
          "expected viewer to be allowed :#{capability}"
      end
      (described_class::CAPABILITIES.keys - allowed).each do |capability|
        expect(host.event_permits?(event, capability)).to be(false),
          "expected viewer to be denied :#{capability}"
      end
    end

    it "immediately denies access once a membership is revoked (destroyed), no caching" do
      member = create(:user)
      membership = create(:event_membership, event: event, user: member, role: "manager")
      host.current_user = member
      expect(host.event_permits?(event, :update_event)).to be(true)

      membership.destroy!

      expect(host.event_permits?(event, :update_event)).to be(false)
    end

    it "raises on an unknown capability rather than silently denying" do
      host.current_user = owner

      expect { host.event_permits?(event, :not_a_capability) }.to raise_error(KeyError)
    end
  end

  describe "#authorize_event!" do
    it "returns true and renders nothing when permitted" do
      host.current_user = owner

      expect(host.authorize_event!(event, :update_event)).to be(true)
      expect(host.rendered).to be_nil
    end

    it "renders 403 Forbidden and returns false when denied" do
      host.current_user = stranger

      expect(host.authorize_event!(event, :update_event)).to be(false)
      expect(host.rendered).to eq(json: { error: "Forbidden" }, status: :forbidden)
    end
  end

  describe "#find_authorized_event!" do
    it "returns the event when permitted" do
      host.current_user = owner

      expect(host.find_authorized_event!(event.id, :view_participants)).to eq(event)
    end

    # Raising (rather than rendering) is what lets every call site keep its
    # own existing rescue and its own 404 copy.
    it "raises RecordNotFound when the caller may not touch it" do
      host.current_user = stranger

      expect { host.find_authorized_event!(event.id, :view_participants) }
        .to raise_error(ActiveRecord::RecordNotFound)
    end

    it "raises RecordNotFound when the event does not exist" do
      host.current_user = owner

      expect { host.find_authorized_event!(SecureRandom.uuid, :view_participants) }
        .to raise_error(ActiveRecord::RecordNotFound)
    end

    it "honours a caller-supplied scope" do
      host.current_user = owner
      event.discard!

      expect { host.find_authorized_event!(event.id, :view_activity, scope: Event.kept) }
        .to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  describe "CAPABILITIES" do
    it "grants :owner every capability — the owner can always do everything" do
      described_class::CAPABILITIES.each do |capability, allowed_roles|
        expect(allowed_roles).to include(:owner), "expected :owner to be allowed :#{capability}"
      end
    end

    it "keeps plan payments, unpublish, delete, and member management owner-only" do
      %i[manage_plan unpublish_event delete_event manage_members].each do |capability|
        expect(described_class::CAPABILITIES.fetch(capability)).to eq([ :owner ])
      end
    end

    it "only ever references :owner or a real EventMembership role" do
      known = [ :owner, *EventMembership::ROLES.map(&:to_sym) ]

      expect(described_class::CAPABILITIES.values.flatten.uniq - known).to be_empty
    end
  end
end
