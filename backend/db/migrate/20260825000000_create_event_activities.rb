class CreateEventActivities < ActiveRecord::Migration[8.1]
  # Queryable activity log for organizer-level actions on their own event —
  # deliberately separate from admin_actions (AdminAction), which is scoped
  # to Rally-staff moderation only (see that table's own migration comment).
  # This one's actor is whoever performed the action, which today is always
  # the event's own organizer (EventsController#update,
  # RegistrationsController#destroy have no admin equivalents), but isn't
  # named "organizer_actions" in case a staff-performed equivalent action
  # ever needs to land in the same table.
  def change
    create_table :event_activities, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :event_id, null: false
      t.uuid :actor_id, null: false
      t.string :action, null: false
      t.jsonb :metadata, default: {}, null: false
      t.datetime :created_at, null: false
    end

    add_index :event_activities, :event_id
    add_index :event_activities, :actor_id
    add_index :event_activities, :action

    add_foreign_key :event_activities, :events
    add_foreign_key :event_activities, :users, column: :actor_id
  end
end
