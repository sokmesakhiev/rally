class CreateAdminActions < ActiveRecord::Migration[8.1]
  # Queryable replacement for Admin::BaseController#log_admin_action's
  # Rails.logger.info-only implementation. Scoped to admin actions only (not
  # organizer-level destroys like EventsController#destroy or
  # RegistrationsController#destroy) — matches today's log_admin_action
  # surface: Admin::EventsController#unpublish/#destroy,
  # Admin::UsersController#suspend/#unsuspend, and RefundsController#create
  # when an admin (not the organizer) issues the refund.
  def change
    create_table :admin_actions, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :admin_id, null: false
      t.string :action, null: false
      t.string :target_type, null: false
      t.uuid :target_id, null: false
      t.jsonb :metadata, default: {}, null: false
      t.datetime :created_at, null: false
    end

    add_index :admin_actions, :admin_id
    add_index :admin_actions, [ :target_type, :target_id ]
    add_index :admin_actions, :action

    add_foreign_key :admin_actions, :users, column: :admin_id
  end
end
