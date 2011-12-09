class CreateVehicles < ActiveRecord::Migration
  def self.up
    create_table :vehicles do |t|
      t.decimal :vehicle_lat
      t.decimal :vehicle_lon
      t.string :vehicle_label
      t.integer :vehicle_id
      t.integer :block_id
      t.integer :route_id
      t.string :vehicle_direction
      t.string :trip_headsign
      t.datetime :gps_poll_time

      t.timestamps
    end
    add_index :vehicles, :vehicle_id
  end

  def self.down
    drop_table :vehicles
  end
end
