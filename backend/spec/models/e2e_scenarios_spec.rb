require "rails_helper"
require Rails.root.join("db/e2e_scenarios")

# The only executable coverage the Playwright seeds get.
#
# `db/e2e_scenarios.rb` is loaded by exactly one controller, in an environment
# RSpec never runs in, so without this file every scenario is unverified code
# that fails for the first time in a nightly browser run — at which point the
# failure looks like "the waitlist journey is broken" rather than "the seed
# doesn't satisfy a validation somebody added last week".
#
# Requiring it by absolute path is deliberate and mirrors the controller:
# the file sits outside the autoload paths on purpose (see its header), so
# there is no constant to reference until something requires it.
RSpec.describe E2eScenarios do
  describe ".names" do
    it "lists only scenarios that actually build" do
      # The failure mode this exists for: someone adds a name to .names for a
      # journey they're about to write, forgets the `when` branch, and the
      # suite discovers it at 3am against a real browser.
      #
      # Each build runs in its own savepoint and is rolled back, because
      # several scenarios deliberately reuse the same addresses
      # (organizer@e2e.rally.test and friends) — predictable emails are the
      # point of a seed. In the real flow the reset endpoint truncates before
      # every build; without the rollback here the second scenario would
      # collide on the unique index and this spec would fail for a reason
      # that has nothing to do with the scenarios being wrong.
      described_class.names.each do |name|
        ActiveRecord::Base.transaction(requires_new: true) do
          expect { described_class.build!(name) }
            .not_to raise_error, "scenario #{name.inspect} is listed in .names but does not build"
          raise ActiveRecord::Rollback
        end
      end
    end

    it "refuses a name it doesn't know, and says which it does" do
      expect { described_class.build!("no-such-world") }
        .to raise_error(described_class::UnknownScenario, /Unknown e2e scenario/)
    end
  end

  # Each of these pins the *property the journey depends on*, not the shape of
  # the data. A seed that builds successfully but has the event unpublished,
  # or the "full" event not actually full, produces a journey failure several
  # steps from its cause.
  describe "the properties journeys rely on" do
    it "gives every seeded user a usable sign-in" do
      world = described_class.build!("paid_event")

      world[:users].each do |role, payload|
        user = User.find(payload[:id])
        expect(user.authenticate(payload[:password]))
          .to be_truthy, "the password returned for #{role} does not authenticate"
        expect(payload[:email]).to eq(user.email)
      end
    end

    it "builds an organizer with exactly one complete, publishable organization" do
      described_class.build!("organizer")

      org = Organization.sole
      # One, because the create-event form only renders the "Presented by"
      # dropdown above one organization — two would silently change the UI
      # every event-creating journey has to drive.
      expect(org.missing_identity_fields).to be_empty
      expect(org.owner.verified?).to be(true)
    end

    it "publishes paid_event, charges for it, and leaves room to register" do
      world = described_class.build!("paid_event")
      event = Event.find(world[:events][:main][:id])

      expect(event).to be_is_published
      expect(event).not_to be_full
      expect(event.accepting_signups?).to be(true)
      # Paid, or the registration journey never reaches the gateway at all —
      # a free registration is written already-paid.
      expect(event.price_cents).to be > 0
      # The registration journey browses the public catalogue to find it.
      expect(Event.publicly_visible).to include(event)
    end

    it "leaves draft_event unpublished and without a plan" do
      world = described_class.build!("draft_event")
      event = Event.find(world[:events][:main][:id])

      expect(event).not_to be_is_published
      # No plan, specifically. The manage page only shows the plan grid when
      # `ev.plan` is nil; with one already set it renders the
      # republish-under-the-same-plan path, which charges nothing — and the
      # paid-publish journey would then quietly test the wrong thing rather
      # than fail.
      expect(event.plan).to be_nil
    end

    it "makes full_event genuinely full, with a paid holder and a spare user" do
      world = described_class.build!("full_event")
      event = Event.find(world[:events][:main][:id])

      expect(event).to be_full
      expect(event.registrations.active.count).to eq(1)
      # Paid, because a free registration is created already-paid and can
      # never exercise the payment half of a waitlist promotion.
      expect(event.price_cents).to be > 0
      expect(world[:users]).to include(:waiter)
    end

    it "gives finished_event unique bibs on an event that has ended" do
      world = described_class.build!("finished_event")
      event = Event.find(world[:events][:main][:id])

      expect(event).to be_ended
      bibs = world[:registrations].values.map { |r| r[:bib_number] }
      expect(bibs.uniq.length).to eq(bibs.length)
      expect(Registration.where(event: event).pluck(:bib_number)).to match_array(bibs)
    end

    it "makes the admin scenario's staff account an admin and nobody else" do
      world = described_class.build!("admin")

      expect(User.find(world[:users][:admin][:id])).to be_admin
      expect(User.find(world[:users][:organizer][:id])).not_to be_admin
      expect(User.find(world[:users][:participant][:id])).not_to be_admin
    end

    it "returns paths rather than bare ids for events" do
      world = described_class.build!("paid_event")
      event = world[:events][:main]

      # Journeys navigate to what they were handed. If these drift from the
      # real routes, every journey breaks at once and none of them say why —
      # so the route shape is written down here and asserted here.
      expect(event[:url]).to eq("/events/#{event[:id]}")
      expect(event[:manage_url]).to eq("/dashboard/events/#{event[:id]}")
    end
  end

  it "uses one published password, so a journey can state what it types" do
    expect(described_class::PASSWORD.length).to be >= 8
  end
end
