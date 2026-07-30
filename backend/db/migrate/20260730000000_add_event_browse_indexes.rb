class AddEventBrowseIndexes < ActiveRecord::Migration[8.1]
  def change
    # Supports the public browse query (EventsController#index):
    #   WHERE is_published = true AND start_at >= now() ORDER BY start_at ASC
    # The existing single-column indexes on is_published and start_at each
    # only help one half of that; a composite covering both the filter and the
    # sort lets Postgres satisfy the whole thing from the index.
    add_index :events, [ :is_published, :start_at ], name: "index_events_on_is_published_and_start_at"

    # Supports the ?category= filter, which is now a first-class way to browse.
    add_index :events, :category
  end
end
