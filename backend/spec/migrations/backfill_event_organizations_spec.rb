require "rails_helper"
require Rails.root.join("db/migrate/20260828041000_backfill_event_organizations")

# Points every pre-existing event at its creator's organization. Worth
# specc'ing for the same reason #330's backfill was: it runs once against real
# rows, and the migration ends by making the column NOT NULL — so anything it
# misses doesn't degrade gracefully, it aborts the deploy.
RSpec.describe BackfillEventOrganizations do
  subject(:run_migration) do
    ActiveRecord::Migration.suppress_messages { described_class.new.up }
  end

  # The column is already NOT NULL by the time the suite runs (schema.rb is
  # loaded, not migrated), so simulate the pre-migration state by dropping the
  # constraint and clearing the column first.
  before do
    ActiveRecord::Migration.suppress_messages do
      ActiveRecord::Base.connection.change_column_null(:events, :organization_id, true)
    end
  end

  # The DDL above and any the migration performs are rolled back with the
  # example (PostgreSQL DDL is transactional), but Rails' cached column
  # metadata is process-level and would otherwise leak into later specs.
  after { Event.reset_column_information }

  def clear_organization_on(event)
    Event.where(id: event.id).update_all(organization_id: nil)
  end

  it "points an event at the organization its creator owns" do
    organizer = create(:user)
    organization = create(:organization, owner: organizer)
    event = create(:event, creator: organizer, organization: organization)
    clear_organization_on(event)

    run_migration

    expect(event.reload.organization_id).to eq(organization.id)
  end

  it "leaves an event that already has an organization untouched" do
    club = create(:organization)
    event = create(:event, :for_organization, presented_by: club)

    run_migration

    expect(event.reload.organization_id).to eq(club.id)
  end

  it "backfills every event a single organizer created" do
    organizer = create(:user)
    organization = create(:organization, owner: organizer)
    events = create_list(:event, 3, creator: organizer, organization: organization)
    events.each { |e| clear_organization_on(e) }

    run_migration

    expect(events.map { |e| e.reload.organization_id }).to all(eq(organization.id))
  end

  # #330's backfill skips users whose account went away, and an event created
  # between the two migrations would also arrive here with nothing to point
  # at. Neither may block the NOT NULL the migration ends with.
  it "creates an organization for a creator who somehow has none" do
    organizer = create(:user)
    organizer.profile.update!(display_name: "Orphaned Organizer")
    event = create(:event, creator: organizer)
    clear_organization_on(event)
    Organization.where(owner_id: organizer.id).delete_all

    expect { run_migration }.to change(Organization, :count).by(1)

    organization = Organization.find(event.reload.organization_id)
    expect(organization.owner_id).to eq(organizer.id)
    expect(organization.name).to eq("Orphaned Organizer")
  end

  it "gives a created fallback organization a valid slug" do
    organizer = create(:user)
    organizer.profile.update!(display_name: "ក្លឹបរត់ភ្នំពេញ")
    event = create(:event, creator: organizer)
    clear_organization_on(event)
    Organization.where(owner_id: organizer.id).delete_all

    run_migration

    expect(Organization.find(event.reload.organization_id).slug)
      .to match(/\A[a-z0-9-]+\z/)
  end

  it "leaves no event without an organization" do
    3.times do
      event = create(:event)
      clear_organization_on(event)
    end

    run_migration

    expect(Event.where(organization_id: nil)).to be_empty
  end

  it "makes the column NOT NULL when it finishes" do
    run_migration

    # Rails caches column metadata per class, and change_column_null doesn't
    # invalidate it — without this the assertion reads the pre-migration
    # definition and passes for the wrong reason.
    Event.reset_column_information
    column = Event.columns.find { |c| c.name == "organization_id" }
    expect(column.null).to be(false)
  end

  it "is idempotent — a second run changes nothing" do
    event = create(:event)
    clear_organization_on(event)
    run_migration
    organization_id = event.reload.organization_id

    ActiveRecord::Migration.suppress_messages do
      ActiveRecord::Base.connection.change_column_null(:events, :organization_id, true)
      described_class.new.up
    end

    expect(event.reload.organization_id).to eq(organization_id)
  end
end
