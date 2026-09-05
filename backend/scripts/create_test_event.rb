#!/usr/bin/env ruby
# Create a test event for load testing
# Usage: bundle exec ruby scripts/create_test_event.rb

require_relative '../config/environment'
require 'faker'

# Configuration
ENVIRONMENT = ENV['RAILS_ENV'] || 'production'
TEST_ORG_NAME = "Load Test Organization"
TEST_EVENT_TITLE = "Load Test Event #{Time.now.strftime('%Y%m%d-%H%M%S')}"
TEST_EVENT_CAPACITY = 1000
TEST_EVENT_PRICE_CENTS = 0  # Free event to avoid payment processing

puts "Creating test event for load testing..."
puts "Environment: #{ENVIRONMENT}"
puts "=" * 50

# Safety check for production
if ENVIRONMENT == 'production'
  puts "⚠️  WARNING: Creating test event in PRODUCTION"
  puts "Ensure:"
  puts "  1. Production has NO real users"
  puts "  2. This is a dedicated test event"
  print "\nContinue? (type 'yes' to confirm): "
  confirmation = gets.chomp
  exit(1) unless confirmation.downcase == 'yes'
end

begin
  # Find or create test organization
  admin_user = User.find_by(admin: true)
  unless admin_user
    puts "Error: No admin user found. Please create an admin user first."
    exit(1)
  end

  organization = Organization.find_or_create_by(slug: 'load-test-org') do |org|
    org.name = TEST_ORG_NAME
    org.owner = admin_user
    org.description = "Organization for load testing events"
    org.verified_at = Time.now
    org.verified_by = admin_user
  end

  puts "✓ Organization: #{organization.name} (#{organization.slug})"

  # Create test event
  event = Event.create!(
    title: TEST_EVENT_TITLE,
    description: "Load testing event - DO NOT REGISTER FOR REAL",
    category: 'running',
    start_at: 1.week.from_now,
    end_at: 1.week.from_now + 2.hours,
    location: "Virtual",
    capacity: TEST_EVENT_CAPACITY,
    price_cents: TEST_EVENT_PRICE_CENTS,
    currency: 'USD',
    plan: 'extra_large',  # 30,000 capacity
    organization: organization,
    creator: admin_user,
    is_published: true
  )

  puts "✓ Event created:"
  puts "  ID: #{event.id}"
  puts "  Title: #{event.title}"
  puts "  Capacity: #{event.capacity}"
  puts "  Price: #{event.price_cents} cents"
  puts "  Published: #{event.is_published}"

  puts "\nUse this event ID for load testing:"
  puts "EVENT_ID=#{event.id}"

rescue => e
  puts "Error creating test event: #{e.message}"
  puts e.backtrace
  exit(1)
end

puts "\n✓ Test event ready for load testing"
