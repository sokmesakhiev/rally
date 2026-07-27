class AddMapLocationToEvents < ActiveRecord::Migration[8.1]
  def change
    # Populated by the Google Maps location picker on the create-event form
    # (see frontend LocationPicker) when the organizer selects a place from
    # autocomplete or drops/drags the pin. `location` (the free-text address
    # string) stays the source of truth for display; lat/lng are only used to
    # link out to Google Maps ("View on map") and are nil for events created
    # before this existed, or when the picker fell back to plain text entry
    # (no Maps API key configured).
    add_column :events, :latitude, :decimal, precision: 10, scale: 6
    add_column :events, :longitude, :decimal, precision: 10, scale: 6

    # Optional link to a Google My Maps / Maps route for point-to-point
    # events (races, rides) — shown as a "View route" link on the event page.
    # Deliberately just a URL, not drawn/stored waypoints.
    add_column :events, :route_map_url, :string
  end
end
