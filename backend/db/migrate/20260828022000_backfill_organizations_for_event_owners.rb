class BackfillOrganizationsForEventOwners < ActiveRecord::Migration[8.1]
  # Gives every existing organizer an Organization to be presented under, so
  # Ticket C (#332) can add events.organization_id as null: false without
  # stranding historical data.
  #
  # "Organizer" here means "has created at least one event". Users who have
  # only ever registered for other people's events get nothing — they're
  # participants, and manufacturing an empty organization for each of them
  # would put thousands of hollow rows behind the public /organizers/:slug
  # namespace.
  #
  # Deliberately uses local, minimal AR classes rather than ::Organization /
  # ::User. A data migration runs against the schema as it was at this point
  # in history; reaching for the real models couples it to whatever those
  # classes look like months from now, and a later validation or callback
  # would break a migration that has already run everywhere.
  class MigrationUser < ActiveRecord::Base
    self.table_name = "users"
  end

  class MigrationProfile < ActiveRecord::Base
    self.table_name = "profiles"
  end

  class MigrationOrganization < ActiveRecord::Base
    self.table_name = "organizations"
  end

  def up
    owner_ids = select_values(<<~SQL)
      SELECT DISTINCT creator_id FROM events WHERE creator_id IS NOT NULL
    SQL

    owner_ids.each do |owner_id|
      # Idempotency: this migration is re-runnable, and a partial failure
      # part-way through a large backfill should be safe to resume.
      next if MigrationOrganization.exists?(owner_id: owner_id)

      user = MigrationUser.find_by(id: owner_id)
      next if user.nil?

      profile = MigrationProfile.find_by(user_id: owner_id)
      name = organization_name_for(user, profile)

      MigrationOrganization.create!(
        owner_id: owner_id,
        name: name,
        slug: unique_slug_for(name),
        # A starting point, not a final choice — organizers set real branding
        # in Ticket G. Using the avatar means the "Presented by" block has
        # something to show on day one instead of a blank square.
        logo_url: profile&.avatar_url,
        created_at: Time.current,
        updated_at: Time.current
      )
    end
  end

  # Irreversible by intent: rolling back would delete organizations that,
  # by the time anyone rolls back, may have had real branding and members
  # added to them. Drop the table via the CreateOrganizations rollback if
  # that's genuinely what's wanted.
  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

  def organization_name_for(user, profile)
    display_name = profile&.display_name.presence
    return display_name if display_name

    # Fall back to the email local-part. Guest checkout can generate
    # "guest-...@guest.rally.invalid" addresses, but those accounts never
    # create events, so they never reach this branch.
    user.email.to_s.split("@").first.presence || "Organizer"
  end

  # Mirrors Organization's own slug generation. Duplicated rather than
  # called into for the same reason the models above are local: this needs
  # to keep behaving the way it did the day it ran.
  def unique_slug_for(name)
    base = name.to_s.parameterize.presence
    # parameterize strips non-ASCII entirely, so a Khmer-only display name
    # ("ក្លឹបរត់ភ្នំពេញ") yields "". Fall back to a stable random slug rather
    # than colliding every such organizer onto the same empty string.
    base ||= "organizer-#{SecureRandom.hex(4)}"
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
