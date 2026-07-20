class CreateRegistrationEventTypes < ActiveRecord::Migration[8.1]
  def change
    create_table :registration_event_types, id: :uuid do |t|
      t.references :registration, null: false, foreign_key: true, type: :uuid, index: true
      t.references :event_type,   null: false, foreign_key: true, type: :uuid, index: true

      t.timestamps
    end

    add_index :registration_event_types,
              [ :registration_id, :event_type_id ],
              unique: true,
              name: "index_reg_event_types_on_reg_and_type"
  end
end
