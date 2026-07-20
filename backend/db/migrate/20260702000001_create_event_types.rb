class CreateEventTypes < ActiveRecord::Migration[8.1]
  def change
    create_table :event_types, id: :uuid do |t|
      t.references :event, null: false, foreign_key: true, type: :uuid, index: true
      t.string  :name,        null: false
      t.text    :description
      t.integer :capacity                        # nil = unlimited per type
      t.integer :price_cents                     # nil = inherit from event
      t.integer :position,    null: false, default: 0

      t.timestamps
    end

    add_index :event_types, [ :event_id, :position ]
  end
end
