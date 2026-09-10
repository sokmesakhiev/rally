# frozen_string_literal: true

# rspec-rails does not include these itself — its RailsExampleGroup pulls in
# CurrentAttributes and ExecutionContext test helpers but not TimeHelpers — so
# `travel`, `travel_to` and `freeze_time` need wiring up explicitly.
#
# Needed by anything asserting on a TTL or an elapsed window (Cable::Ticket's
# 30-second expiry, for one).
require "active_support/testing/time_helpers"

RSpec.configure do |config|
  config.include ActiveSupport::Testing::TimeHelpers
end
