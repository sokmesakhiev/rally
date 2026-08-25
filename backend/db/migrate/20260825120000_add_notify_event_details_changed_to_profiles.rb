class AddNotifyEventDetailsChangedToProfiles < ActiveRecord::Migration[8.1]
  def change
    add_column :profiles, :notify_event_details_changed, :boolean, default: true, null: false
  end
end
