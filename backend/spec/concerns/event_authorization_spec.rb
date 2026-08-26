require "rails_helper"

# Unit spec for the concern itself. The per-endpoint behaviour it replaced is
# already covered by the request specs (events_spec, registrations_spec,
# refunds_spec, results_spec, waitlist_entries_spec, survey_responses_spec,
# event_plan_payments_spec) — those passing unchanged is the real proof that
# this refactor changed nothing.
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

    # This is the assertion that pins "no behaviour change". Roles exist and
    # resolve, but grant nothing until #278 edits CAPABILITIES — so every
    # endpoint still answers exactly as it did before this refactor.
    it "grants a member nothing yet, whatever their role" do
      EventMembership::ROLES.each do |role|
        member = create(:user)
        create(:event_membership, event: event, user: member, role: role)
        host.current_user = member

        described_class::CAPABILITIES.each_key do |capability|
          expect(host.event_permits?(event, capability)).to be(false),
            "expected #{role} to be denied :#{capability} until role gating lands"
        end
      end
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
    it "is owner-only across the board while role gating is pending" do
      expect(described_class::CAPABILITIES.values.flatten.uniq).to eq([ :owner ])
    end

    it "only ever references :owner or a real EventMembership role" do
      known = [ :owner, *EventMembership::ROLES.map(&:to_sym) ]

      expect(described_class::CAPABILITIES.values.flatten.uniq - known).to be_empty
    end
  end
end
