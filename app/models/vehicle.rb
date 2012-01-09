class Vehicle < ActiveRecord::Base
  def update_realtime!(data)
    # If there's no lat or lng, then it's trash; don't even bother.
    if data["lat"].strip == '' or data["lng"].strip == ''
      return nil
    end

    self.vehicle_lat = data["lat"]
    self.vehicle_lon = data["lng"]

    # For the rest of the stuff, set if the data is not empty.  Otherwise,
    # don't set, in case you're going to overwrite data.
    self.vehicle_label = (data["label"] unless data["label"].strip == '') or self.vehicle_label

    directions = ['NorthBound', 'EastBound', 'SouthBound', 'WestBound']
    self.vehicle_direction = (data["Direction"] if directions.include? data["Direction"]) or self.vehicle_direction

    self.block_id = data["BlockID"]
    self.trip_headsign = (data["destination"] unless data["destination"].strip == '') or self.trip_headsign or ''
    self.gps_poll_time = Time.now - data["Offset"].to_i.minutes

    self.save
    return self
  end
end
