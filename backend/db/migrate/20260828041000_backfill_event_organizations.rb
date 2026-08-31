class BackfillEventOrganizations < ActiveRecord::Migration[8.1]
  # Points every existing event at its creator's organization, then makes the
  # column required.
  #
  # The mapping is unambiguous for existing data precisely because
  # BackfillOrganizationsForEventOwners (#330) created exactly one
  # organization per event-creating user. That one-to-one relationship only
  # holds for rows that predate this feature — from here on a user may own
  # several organizations, which is why EventsController#create requires an
  # explicit organization_id rather than inferring one.
  #
  # Local AR classes rather than ::Event / ::Organization for the same reason
  # as #330's backfill: a data migration should keep behaving the way it did
  # the day it ran, not track whatever those models look like later.
  class MigrationEvent < ActiveRecord::Base
    self.table_name = "events"
  end

  class MigrationOrganization < ActiveRecord::Base
    self.table_name = "organizations"
  end

  def up
    # One UPDATE rather than a row-by-row loop — this touches every event in
    # the table, and the join is on an indexed column both sides.
    execute(<<~SQL)
      UPDATE events
         SET organization_id = organizations.id
        FROM organizations
       WHERE organizations.owner_id = events.creator_id
         AND events.organization_id IS NULL
    SQL

    # Belt and braces. #330's backfill skips users whose account was deleted
    # between then and now, and an event created in the window between these
    # two migrations would also land here with no organization. Neither
    # should be able to block the NOT NULL below.
    orphan_count = MigrationEvent.where(organization_id: nil).count
    if orphan_count.positive?
      say "#{orphan_count} event(s) had no organization for their creator; creating one each"
      backfill_orphans
    end

    change_column_null :events, :organization_id, false
  end

  def down
    change_column_null :events, :organization_id, true
  end

  private

  def backfill_orphans
    MigrationEvent.where(organization_id: nil).find_each do |event|
      next if event.creator_id.nil?

      organization = MigrationOrganization.find_by(owner_id: event.creator_id)
      organization ||= create_fallback_organization(event.creator_id)

      event.update_columns(organization_id: organization.id)
    end
  end

  def create_fallback_organization(owner_id)
    name = select_value(
      "SELECT COALESCE(NULLIF(p.display_name, ''), split_part(u.email, '@', 1), 'Organizer') " \
      "FROM users u LEFT JOIN profiles p ON p.user_id = u.id WHERE u.id = #{connection.quote(owner_id)}"
    ) || "Organizer"

    MigrationOrganization.create!(
      owner_id: owner_id,
      name: name,
      slug: unique_slug_for(name),
      created_at: Time.current,
      updated_at: Time.current
    )
  end

  # Mirrors Organization's own generation, including the non-ASCII fallback —
  # a Khmer-only name parameterizes to "", which would otherwise collide every
  # such organizer onto the same empty slug.
  def unique_slug_for(name)
    base = name.to_s.parameterize.presence || "organizer-#{SecureRandom.hex(4)}"
    base = base.first(60)

    candidate = base
    suffix = 2
    while MigrationOrganization.exists?(slug: candidate)
      candidate = "#{base}-#{suffix}"
      suffix += 1
    end
    candidate
  end
end
