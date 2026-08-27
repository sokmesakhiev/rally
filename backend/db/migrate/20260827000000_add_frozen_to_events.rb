class AddFrozenToEvents < ActiveRecord::Migration[8.1]
  def change
    add_column :events, :frozen_at, :datetime
    add_column :events, :freeze_reason, :string
    add_index :events, :frozen_at, where: "frozen_at IS NOT NULL"
  end
end
