#!/usr/bin/env ruby
# Clean up test data from load testing
# Usage: bundle exec ruby scripts/cleanup_test_data.rb

require_relative '../config/environment'

# Configuration
ENVIRONMENT = ENV['RAILS_ENV'] || 'production'
TEST_EVENT_ID = ENV['TEST_EVENT_ID']
TEST_ORG_SLUG = ENV['TEST_ORG_SLUG'] || 'load-test-org'
DRY_RUN = ENV['DRY_RUN'] == 'true'

puts "Test Data Cleanup Script"
puts "Environment: #{ENVIRONMENT}"
puts "Dry Run: #{DRY_RUN ? 'YES' : 'NO'}"
puts "=" * 50

# Safety check for production
if ENVIRONMENT == 'production'
  puts "⚠️  WARNING: Running cleanup in PRODUCTION"
  puts "This will DELETE test data including:"
  puts "  - Test event registrations"
  puts "  - Test event waitlist entries"
  puts "  - Test event activities"
  puts "  - Test organization (if specified)"
  puts "\nData to be cleaned:"

  if TEST_EVENT_ID
    event = Event.find_by(id: TEST_EVENT_ID)
    if event
      puts "  Event: #{event.title} (#{event.registrations.count} registrations)"
    else
      puts "  Event ID #{TEST_EVENT_ID} not found"
    end
  end

  if TEST_ORG_SLUG
    org = Organization.find_by(slug: TEST_ORG_SLUG)
    if org
      puts "  Organization: #{org.name} (#{org.events.count} events)"
    end
  end

  print "\nContinue? (type 'yes' to confirm): "
  confirmation = gets.chomp
  exit(1) unless confirmation.downcase == 'yes'
end

begin
  # Clean up specific event
  if TEST_EVENT_ID
    event = Event.find_by(id: TEST_EVENT_ID)
    if event
      puts "\nCleaning up event: #{event.title}"

      # Count records before deletion
      registration_count = event.registrations.count
      waitlist_count = event.waitlist_entries.count
      activity_count = event.event_activities.count

      puts "  Registrations: #{registration_count}"
      puts "  Waitlist entries: #{waitlist_count}"
      puts "  Activities: #{activity_count}"

      unless DRY_RUN
        # Delete registrations (cascade to related records)
        event.registrations.destroy_all

        # Delete waitlist entries
        event.waitlist_entries.destroy_all

        # Delete activities
        event.event_activities.destroy_all

        # Delete the event
        event.destroy!

        puts "  ✓ Event deleted"
      else
        puts "  [DRY RUN] Would delete event and all related data"
      end
    else
      puts "Event ID #{TEST_EVENT_ID} not found"
    end
  end

  # Clean up test organization
  if TEST_ORG_SLUG && !TEST_EVENT_ID
    org = Organization.find_by(slug: TEST_ORG_SLUG)
    if org
      puts "\nCleaning up organization: #{org.name}"

      # Count events
      event_count = org.events.count

      puts "  Events: #{event_count}"

      unless DRY_RUN
        # Delete all events in organization
        org.events.each do |event|
          event.registrations.destroy_all
          event.waitlist_entries.destroy_all
          event.event_activities.destroy_all
          event.destroy!
        end

        # Delete organization
        org.destroy!

        puts "  ✓ Organization deleted"
      else
        puts "  [DRY RUN] Would delete organization and all events"
      end
    else
      puts "Organization #{TEST_ORG_SLUG} not found"
    end
  end

  # Clean up test users (optional - users created during load testing)
  if ENV['CLEANUP_TEST_USERS'] == 'true'
    puts "\nCleaning up test users..."

    # Find users with load test pattern emails
    test_users = User.where('email LIKE ?', '%test%@example.com')
    puts "  Found #{test_users.count} test users"

    unless DRY_RUN
      test_users.each do |user|
        # Delete registrations
        user.registrations.destroy_all
        # Delete user
        user.destroy!
      end
      puts "  ✓ Test users deleted"
    else
      puts "  [DRY RUN] Would delete #{test_users.count} test users"
    end
  end

  puts "\n✓ Cleanup complete"

rescue => e
  puts "Error during cleanup: #{e.message}"
  puts e.backtrace
  exit(1)
end
