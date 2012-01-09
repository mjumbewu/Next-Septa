class EstimatesController < ApplicationController
  SERVICE_IDS = ["7", "1", "1", "1", "1", "1", "5"]

  def index
    create_headers

    service_id = SERVICE_IDS[Time.zone.now.wday]

    route_id = @route.route_id
    route_name = @route.route_short_name
    direction_id = params[:direction]

    vehicles = get_real_time_locations(route_id, route_name)
    route_direction = get_route_direction(route_id, direction_id)
    stops = get_stops(route_direction)
    trips = get_route_trips(route_direction, service_id).to_ary

    vehicles_data = []

    vehicles.each do |vehicle|
      # Attempt to match each vehicle to a trip and calculate the lateness on
      # on that trip.
      nearest_stop = get_nearest_stop(stops, vehicle)
      departures = get_scheduled_departure_times(trips, nearest_stop)
      trip, departure, lateness = get_estimated_lateness(trips, departures, vehicle)

      vehicle_data = {
        :lat => vehicle.vehicle_lat,
        :lng => vehicle.vehicle_lon,
        :label => vehicle.vehicle_label,
        :VehicleID => vehicle.vehicle_id,
        :Direction => vehicle.vehicle_direction,
        :destination => vehicle.trip_headsign,
        :gps_poll_time => vehicle.gps_poll_time
      }

      if lateness != nil
        vehicle_data[:lateness] = lateness

        # It doesn't matter what block ID the vehicle _thought_ it belonged to;
        # all the user will care about is which block the vehicle is closest to,
        # so we reassign ("fudge") the block here.
        vehicle_data[:BlockID] = trip.block_id

        # The trip has now been associated with a vehicle, so remove it from the
        # pool.
        trips.delete trip

        # Fill in some other potentially useful information
        vehicle_data[:expected] = departure.departure_time
        vehicle_data[:nearest_stop] = nearest_stop.stop_name
      end

      vehicles_data.push vehicle_data
    end

    render :json => {"bus" => vehicles_data}
  end

  def get_real_time_locations(route_id, route_name)
    # Get the real-time bus location data from SEPTA ad return the response as
    # a JSON-interpreted hash.

    url = "http://www3.septa.org/transitview/bus_route_data/#{route_name}"
    resp = Resourceful.get(url)

    vehicles_data = ActiveSupport::JSON.decode(resp.body)["bus"]

    # Store the vehicles.  Grab the ones that are already in the database that
    # have the same vehicle number (do it all at once instead of separately for
    # each vehicle).  Then we'll just update these ones instead of saving over
    # them (the new data might be missing some values).  This is like
    # get_or_create in Django.
    vehicle_ids = vehicles_data.collect {|data| data["VehicleID"] }
    vehicles = Vehicle.select("*")
      .where("vehicle_id in (?)", vehicle_ids)

    Vehicle.transaction do
      vehicles_data.each do |vehicle_data|
        vehicle_id = vehicle_data["VehicleID"].to_i

        vehicle_index = vehicles.index { |v| v.vehicle_id == vehicle_id }
        if vehicle_index == nil
          vehicle = Vehicle.new(:route_id => route_id, :vehicle_id => vehicle_id)
        else
          vehicle = vehicles[vehicle_index]
        end

        vehicle.update_realtime!(vehicle_data)
      end
    end  # transaction

    # Now that we have these stored, pull the cached values out and use those.
    # This might explode after a while, so we time-box it.
    vehicles = Vehicle.select("*")
      .where("route_id = ? AND gps_poll_time >= ?", route_id, Time.now - 30.minutes)

    return vehicles
  end

  def get_route_direction(route_id, direction_id)
    # Get the RouteDirection object that corresponds to the given Route ID and
    # Direction ID.

    RouteDirection.select("*")
      .where("route_id = '#{route_id}' AND direction_id = '#{direction_id}'")
      .first
  end

  def get_stops(route_direction)
    # Get all the Stop objects that fall along the given RouteDirection object.

    Stop.select("*")
      .joins("JOIN simplified_stops ss ON stops.stop_id = ss.stop_id")
      .where("ss.route_id = '#{route_direction.route_id}' AND ss.direction_id = '#{route_direction.direction_id}'")
  end

  def get_nearest_stop(stops, vehicle)
    # Given a list of stops and a real-time vehicle object, determine which
    # Stop is closest to the Vehicle at the time that the Vehicle's GPS was
    # last polled.

    nearest_stop = nil
    distance = nil

    stops.each do |stop|
      current_distance = Math.sqrt((vehicle.vehicle_lat - stop.stop_lat)**2 +
                                   (vehicle.vehicle_lon - stop.stop_lon)**2)
      if distance == nil or current_distance < distance
        nearest_stop = stop
        distance = current_distance
      end
    end

    return nearest_stop
  end

  def get_route_trips(route_direction, service_id)
    # Get a collection of objects containing Trip data for all the trips along
    # a given route.

    Trip.select("*")
        .where("route_id = ? AND direction_id = ? AND service_id = ?",
               route_direction.route_id, route_direction.direction_id,
               service_id)
  end

  def get_scheduled_departure_times(trips, stop)
    # Get a collection of StopTime objects for all the scheduled departure times
    # from the given stop along the given trips.

    trip_ids = []
    trips.each do |trip|
      trip_ids.push trip.trip_id
    end

    StopTime.select("departure_time, trip_id")
        .where("stop_id = ? AND trip_id IN (?)", stop.stop_id, trip_ids)
        .order("departure_time")
  end

  def interpret_time(time_string)
    # Given a string in the format 'HH:MM:SS', return a time object.  If the
    # time is no more than 6 hours before the current time, use today's date as
    # the time's date.  Otherwise, use tomorrow's date.

    time_hour, time_minute, time_second = time_string.split(':').map {|piece| piece.to_i }

    # Be sure to always interpret in eastern time.
    eastern_offset = (Time.now.isdst ? -4 : -5).hours
    local_offset = (Time.now.utc_offset - eastern_offset)

    # We want the year, month, and day from the current time, but expressed as
    # eastern time.  Take now and subtract the offset to get the correct day.
    now = Time.now - local_offset

    # Ruby is going to construct the time in the local zone, so offset it to
    # eastern.  For example, if we have 14:30:00 and our servers are in
    # California, Ruby will say it's 2:30 Pacific when we really want 2:30
    # Eastern.  Add the offset.
    time = Time.new(now.year, now.month, now.day, time_hour % 24, time_minute, time_second) + local_offset

    # If the hour is after midnight but before 6am, and we're currently after
    # 6pm, move the interpretation forward one day.
    if now.hour >= 18 && time_hour >= 24 && time_hour < 6
      time += 1.day
    end

    # If the hour is before midnight but after 6pm, and we're currently before
    # 6am, move the interpretation back one day.
    if now.hour < 6 && time_hour < 24 && time_hour >= 18
      time -= 1.day
    end

    return time
  end

  def get_estimated_lateness(trips, departures, vehicle)
    # Get an estimate of how late the given vehicle is according to the given
    # trip and stoptime data.  Use the departure times to determine which is the
    # Trip nearest to the given Vehicle's real-time information.

    actual_time = vehicle.gps_poll_time

    nearest_trip = nil
    nearest_departure = nil
    lateness = nil

    departures.each do |departure|
      # get the corresponding trip
      trip_index = trips.index {|t| t.trip_id == departure.trip_id }
      trip = trips[trip_index]

      # skip this trip if it is not in the vehicle's direction of travel
      next unless same_direction?(trip, vehicle)

      scheduled_time = interpret_time(departure.departure_time)

      current_lateness = actual_time - scheduled_time

      if lateness == nil or current_lateness.abs < lateness.abs
        lateness = current_lateness
        nearest_trip = trip
        nearest_departure = departure
      end
    end

    if lateness == nil
      return nil, nil, nil
    else
      return nearest_trip, nearest_departure, (lateness / 60).round
    end
  end

  def same_direction?(trip, vehicle)
    # Return true if the Vehicle is (known to be) travelling in the direction
    # of the Trip.

    #####
    # This bit uses the destination/trip_headsign to check direction.
#    similarity_threshold = 0.8
#
#    similarity = jaccard_similarity(trip.trip_headsign, vehicle.trip_headsign)
#    return (similarity >= similarity_threshold)
    #####

    #####
    # Sometimes (often?) the headsign is an empty string.  That's not helpful.
    # Sometimes the headsign says something other than what you'd expect, like
    # when a route is diverted.  That's also not always helpful.
    # So, here, we use the Direction/direction_id to check direction instead.
    puts trip.direction_id
    puts vehicle.vehicle_direction
    puts
    return (trip.direction_id.to_i == 0 && (vehicle.vehicle_direction == 'NorthBound' || vehicle.vehicle_direction == 'EastBound')) ||
           (trip.direction_id.to_i == 1 && (vehicle.vehicle_direction == 'SouthBound' || vehicle.vehicle_direction == 'WestBound'))
    #####
  end

  def jaccard_similarity(s, t)
    # Calculate the similarity between the two given strings s and t using the
    # Jaccard index -- the ratio of the number of similar characters in the
    # strings to the total number of (unique) characters.

    return 0 if s == nil || t == nil || (s.length == 0 && t.length == 0)

    similar_chars = ''
    all_chars = ''

    # get the unique characters in common
    s.downcase.each_char do |c|
      if t.downcase.include? c and !similar_chars.include? c
        similar_chars += c
      end
    end

    # get all the unique characters
    (s+t).downcase.each_char do |c|
      if !all_chars.include? c
        all_chars += c
      end
    end

    return similar_chars.length.to_f / all_chars.length.to_f
  end
end
