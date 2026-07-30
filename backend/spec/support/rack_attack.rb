# frozen_string_literal: true

# Rack::Attack is disabled in the test env by default (see
# config/initializers/rack_attack.rb for why — it would otherwise turn
# ordinary auth specs into spurious 429s). Tag an example or group with
# `:rack_attack` to turn it on just for that example, with counters cleared
# on both sides so throttle state never leaks between examples.
RSpec.configure do |config|
  config.around(:each, :rack_attack) do |example|
    Rack::Attack.cache.store.clear
    Rack::Attack.enabled = true
    example.run
  ensure
    Rack::Attack.enabled = false
    Rack::Attack.cache.store.clear
  end
end
