require "rails_helper"
require Rails.root.join("db/migrate/20260828022000_backfill_organizations_for_event_owners")

# Data migrations are the one kind of migration worth specc'ing: they run once
# against real production rows, and getting one wrong is not something a
# rollback reliably fixes. This one has to give every existing organizer an
# Organization so Ticket C (#332) can add events.organization_id as
# null: false without stranding historical data.
RSpec.describe BackfillOrganizationsForEventOwners do
  subject(:run_migration) do
    ActiveRecord::Migration.suppress_messages { described_class.new.up }
  end

  # An organization to hang test events off, owned by someone who never
  # creates an event — so the migration never has a reason to touch it.
  #
  # It exists because of the bind this spec is in: since #332 the events
  # factory builds an organization for every event's creator, which is exactly
  # the row the migration is supposed to create, so it would (correctly) skip
  # them and the spec would assert against factory data. Earlier attempts
  # solved that by dropping the events.organization_id NOT NULL and nulling
  # the column, but DDL inside DatabaseCleaner's per-example transaction
  # proved unreliable — it leaked organizations between examples and every
  # count came out four too high.
  #
  # Parking the event on an unrelated organization gets the same result with
  # no schema surgery: the creator genuinely has no organization of their own,
  # which is precisely the pre-#330 state being reproduced.
  let!(:parking_organization) { create(:organization) }

  # Builds an event whose creator owns no organization, the way every event
  # looked before #330 ran.
  def create_event_without_organization(creator)
    event = create(:event, creator: creator)
    creators_own_organization = event.organization

    Event.where(id: event.id).update_all(organization_id: parking_organization.id)
    creators_own_organization.destroy!

    event.reload
  end

  # Assertions scope to the organizer under test rather than the whole table,
  # since the parking organization is always present.
  def organizations_for(user)
    Organization.where(owner_id: user.id)
  end

  it "creates one organization per user who has created an event" do
    organizer = create(:user)
    create_event_without_organization(organizer)

    expect { run_migration }.to change { organizations_for(organizer).count }.from(0).to(1)
  end

  it "creates a single organization for an organizer with several events" do
    organizer = create(:user)
    3.times { create_event_without_organization(organizer) }

    run_migration

    expect(organizations_for(organizer).count).to eq(1)
  end

  # Manufacturing an empty organization for every participant would put
  # thousands of hollow rows behind the public /organizers/:slug namespace.
  it "creates nothing for a user who has only ever registered for events" do
    participant = create(:user)
    event = create_event_without_organization(create(:user))
    create(:registration, user: participant, event: event)

    run_migration

    expect(organizations_for(participant)).to be_empty
  end

  it "names the organization from the organizer's display name" do
    organizer = create(:user)
    organizer.profile.update!(display_name: "Phnom Penh Runners")
    create_event_without_organization(organizer)

    run_migration

    expect(organizations_for(organizer).sole.name).to eq("Phnom Penh Runners")
  end

  it "falls back to the email local-part when there is no display name" do
    organizer = create(:user, email: "sokmesa@example.com")
    organizer.profile.update!(display_name: nil)
    create_event_without_organization(organizer)

    run_migration

    expect(organizations_for(organizer).sole.name).to eq("sokmesa")
  end

  it "seeds logo_url from the organizer's existing avatar" do
    organizer = create(:user)
    organizer.profile.update!(avatar_url: "https://example.com/avatar.png")
    create_event_without_organization(organizer)

    run_migration

    expect(organizations_for(organizer).sole.logo_url).to eq("https://example.com/avatar.png")
  end

  it "gives every organization a valid, unique slug" do
    organizers = Array.new(3) do
      create(:user).tap do |organizer|
        organizer.profile.update!(display_name: "Runners Club")
        create_event_without_organization(organizer)
      end
    end

    run_migration

    slugs = Organization.where(owner_id: organizers.map(&:id)).pluck(:slug)
    expect(slugs.length).to eq(3)
    expect(slugs.uniq.length).to eq(3)
    expect(slugs).to all(match(/\A[a-z0-9-]+\z/))
  end

  # The app is bilingual by design, so a Khmer-only display name is a normal
  # case — #parameterize strips non-ASCII entirely, which would otherwise
  # collide every such organizer onto the same empty slug.
  it "handles display names with no ASCII to slugify" do
    organizers = Array.new(2) do
      create(:user).tap do |organizer|
        organizer.profile.update!(display_name: "ក្លឹបរត់ភ្នំពេញ")
        create_event_without_organization(organizer)
      end
    end

    run_migration

    slugs = Organization.where(owner_id: organizers.map(&:id)).pluck(:slug)
    expect(slugs.length).to eq(2)
    expect(slugs.uniq.length).to eq(2)
    expect(slugs).to all(match(/\Aorganizer-[0-9a-f]{8}\z/))
  end

  # A partial failure part-way through a large backfill should be safe to
  # resume, and re-running the whole migration must not duplicate anyone.
  it "is idempotent — a second run creates nothing further" do
    create_event_without_organization(create(:user))
    run_migration

    expect { ActiveRecord::Migration.suppress_messages { described_class.new.up } }
      .not_to change(Organization, :count)
  end

  it "leaves organizations created by an earlier partial run untouched" do
    organizer = create(:user)
    create_event_without_organization(organizer)

    # The row a half-finished earlier run would have left behind.
    existing = Organization.create!(owner_id: organizer.id, name: "Already Here", slug: "already-here")

    run_migration

    expect(organizations_for(organizer)).to contain_exactly(existing)
    expect(existing.reload.name).to eq("Already Here")
  end

  it "is irreversible rather than silently deleting organizations" do
    expect { described_class.new.down }.to raise_error(ActiveRecord::IrreversibleMigration)
  end
end
