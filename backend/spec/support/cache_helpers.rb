# frozen_string_literal: true

# `config/environments/test.rb` sets `cache_store = :null_store`, so every
# Rails.cache write is discarded and every read returns nil. That's a sensible
# default — it stops one example's cached value leaking into the next — but it
# means anything actually built *on* Rails.cache cannot be tested at all
# without swapping the store first, and would otherwise pass vacuously.
#
# Tag an example or group `:with_cache` to get a real memory store, isolated
# per example and restored afterwards. See Cable::Ticket, which uses Solid
# Cache in production precisely because it is shared across ECS tasks.
RSpec.configure do |config|
  config.around(:each, :with_cache) do |example|
    original = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
  ensure
    Rails.cache = original
  end
end
