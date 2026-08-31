require "rails_helper"
require Rails.root.join("db/migrate/20260828022000_backfill_organizations_for_event_owners")

# Data migrations are the one kind of migration worth specc'ing: they run once
# against real production rows, and getting one wrong is not something a
# rollback reliably fixes. This one has to give every existing organizer an
# Organization so Ticket C (#332) can add events.organization_id as
# null: false without stranding historical data.
RSpec.describe BackfillOrganizationsForEventOwners do
  # Rewinds to the world as it was before #330 ran, then runs the migration.
  #
  # This reset is load-bearing. Since #332 the events factory builds an
  # organization for every event, so fixtures arrive here already holding the
  # rows this migration is supposed to create — and the migration would
  # (correctly) skip them, leaving the spec asserting against factory data
  # instead of migration output. Dropping the NOT NULL is safe because
  # PostgreSQL DDL is transactional, so the example's rollback undoes it.
  subject(:run_migration) do
    rewind_to_pre_organizations_state!
    ActiveRecord::Migration.suppress_messages { described_class.new.up }
  end

  def rewind_to_pre_organizations_state!
    ActiveRecord::Migration.suppress_messages do
      ActiveRecord::Base.connection.change_column_null(:events, :organization_id, true)
    end
    Event.update_all(organization_id: nil)
    Organization.delete_all
  end

  it "creates one organization per user who has created an event" do
    organizer = create(:user)
    create(:event, creator: organizer)

    run_migration

    # Absolute count, not `change(...).by(1)` — the rewind inside
    # `run_migration` clears the table first, so a relative matcher would
    # measure the delete and the create cancelling out and report no change.
    expect(Organization.count).to eq(1)
    expect(Organization.sole.owner_id).to eq(organizer.id)
  end

  it "creates a single organization for an organizer with several events" do
    organizer = create(:user)
    create_list(:event, 3, creator: organizer)

    run_migration

    expect(Organization.where(owner_id: organizer.id).count).to eq(1)
  end

  # Manufacturing an empty organization for every participant would put
  # thousands of hollow rows behind the public /organizers/:slug namespace.
  it "creates nothing for a user who has only ever registered for events" do
    participant = create(:user)
    create(:registration, user: participant, event: create(:event))

    run_migration

    expect(Organization.where(owner_id: participant.id)).to be_empty
  end

  it "names the organization from the organizer's display name" do
    organizer = create(:user)
    organizer.profile.update!(display_name: "Phnom Penh Runners")
    create(:event, creator: organizer)

    run_migration

    expect(Organization.sole.name).to eq("Phnom Penh Runners")
  end

  it "falls back to the email local-part when there is no display name" do
    organizer = create(:user, email: "sokmesa@example.com")
    organizer.profile.update!(display_name: nil)
    create(:event, creator: organizer)

    run_migration

    expect(Organization.sole.name).to eq("sokmesa")
  end

  it "seeds logo_url from the organizer's existing avatar" do
    organizer = create(:user)
    organizer.profile.update!(avatar_url: "https://example.com/avatar.png")
    create(:event, creator: organizer)

    run_migration

    expect(Organization.sole.logo_url).to eq("https://example.com/avatar.png")
  end

  it "gives every organization a valid, unique slug" do
    3.times do
      organizer = create(:user)
      organizer.profile.update!(display_name: "Runners Club")
      create(:event, creator: organizer)
    end

    run_migration

    slugs = Organization.pluck(:slug)
    expect(slugs.uniq.length).to eq(3)
    expect(slugs).to all(match(/\A[a-z0-9-]+\z/))
  end

  # The app is bilingual by design, so a Khmer-only display name is a normal
  # case — #parameterize strips non-ASCII entirely, which would otherwise
  # collide every such organizer onto the same empty slug.
  it "handles display names with no ASCII to slugify" do
    2.times do
      organizer = create(:user)
      organizer.profile.update!(display_name: "ក្លឹបរត់ភ្នំពេញ")
      create(:event, creator: organizer)
    end

    run_migration

    slugs = Organization.pluck(:slug)
    expect(slugs.uniq.length).to eq(2)
    expect(slugs).to all(match(/\Aorganizer-[0-9a-f]{8}\z/))
  end

  # A partial failure part-way through a large backfill should be safe to
  # resume, and re-running the whole migration must not duplicate anyone.
  it "is idempotent — a second run creates nothing further" do
    create(:event, creator: create(:user))
    run_migration

    expect { ActiveRecord::Migration.suppress_messages { described_class.new.up } }
      .not_to change(Organization, :count)
  end

  it "leaves organizations created by an earlier partial run untouched" do
    organizer = create(:user)
    create(:event, creator: organizer)

    # Rewind first, then plant the row a half-finished earlier run would have
    # left behind — going through `run_migration` would wipe it.
    rewind_to_pre_organizations_state!
    existing = Organization.create!(owner_id: organizer.id, name: "Already Here", slug: "already-here")

    ActiveRecord::Migration.suppress_messages { described_class.new.up }

    expect(Organization.where(owner_id: organizer.id)).to contain_exactly(existing)
    expect(existing.reload.name).to eq("Already Here")
  end

  it "is irreversible rather than silently deleting organizations" do
    expect { described_class.new.down }.to raise_error(ActiveRecord::IrreversibleMigration)
  end
end
