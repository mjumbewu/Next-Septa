class EstimatesController < ApplicationController
  SERVICE_IDS = ["7", "1", "1", "1", "1", "1", "5"]

  def index
    create_headers

    service_id = SERVICE_IDS[Time.zone.now.wday]

    route_id = @route.route_id
    route_name = @route.route_short_name
    direction_id = params[:direction]

    vehicles = get_real_time_locations(route_name)
    route_direction = get_route_direction(route_id, direction_id)
    stops = get_stops(route_direction)
    trips = get_route_trips(route_direction, service_id).to_ary

    vehicles.each do |vehicle|
      # Attempt to match each vehicle to a trip and calculate the lateness on
      # on that trip.
      nearest_stop = get_nearest_stop(stops, vehicle)
      departures = get_scheduled_departure_times(trips, nearest_stop)
      trip, departure, lateness = get_estimated_lateness(trips, departures, vehicle)

      if lateness != nil
        vehicle["lateness"] = lateness

        # It doesn't matter what block ID the vehicle _thought_ it belonged to;
        # all the user will care about is which block the vehicle is closest to,
        # so we reassign ("fudge") the block here.
        vehicle["BlockID"] = trip.block_id

        # The trip has now been associated with a vehicle, so remove it from the
        # pool.
        trips.delete trip

        # Fill in some other potentially useful information
        vehicle["expected"] = departure.departure_time
        vehicle["nearest_stop"] = nearest_stop.stop_name
      end
    end

    render :json => {"bus" => vehicles}
  end

  def get_real_time_locations(route_name)
    # Get the real-time bus location data from SEPTA ad return the response as
    # a JSON-interpreted hash.

    url = "http://www3.septa.org/transitview/bus_route_data/#{route_name}"
    resp = Resourceful.get(url)

    return ActiveSupport::JSON.decode(resp.body)["bus"]
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

    vehicle_lat = vehicle["lat"].to_f
    vehicle_lon = vehicle["lng"].to_f

    nearest_stop = nil
    distance = 10000000000000000000

    stops.each do |stop|
      current_distance = Math.sqrt((vehicle_lat - stop.stop_lat)**2 + (vehicle_lon - stop.stop_lon)**2)
      if current_distance < distance
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

    time_pieces = time_string.split(':')

    now = Time.now
    time = Time.new(now.year, now.month, now.day, time_pieces[0].to_i % 24, time_pieces[1].to_i, time_pieces[2].to_i)
    if time < (now - 6.hours)
      time += 1.day
    end

    return time
  end

  def get_estimated_lateness(trips, departures, vehicle)
    # Get an estimate of how late the given vehicle is according to the given
    # trip and stoptime data.  Use the departure times to determine which is the
    # Trip nearest to the given Vehicle's real-time information.

    actual_time = Time.now - vehicle["Offset"].to_i.minutes

    nearest_trip = nil
    nearest_departure = nil
    lateness = nil

    departures.each do |departure|
      # get the corresponding trip
      trip = nil
      trips.each do |t|
        if t.trip_id == departure.trip_id
          trip = t
          break
        end
      end

      # skip this trip if it is not in the vehicle's direction of travel
      next unless same_direction?(trip, vehicle)

      scheduled_time = interpret_time(departure.departure_time)

      current_lateness = actual_time - scheduled_time

      if lateness == nil || current_lateness.abs < lateness.abs
        lateness = current_lateness
        nearest_trip = trip
        nearest_departure = departure
      end
    end

    return nil, nil if lateness == nil
    return nearest_trip, nearest_departure, (lateness / 60).round
  end

  def same_direction?(trip, vehicle)
    # Return true if the Vehicle is (known to be) travelling in the direction
    # of the Trip.

    similarity_threshold = 0.8

    similarity = jaccard_similarity(trip.trip_headsign, vehicle["destination"])
    return (similarity >= similarity_threshold)
  end

  def jaccard_similarity(s, t)
    # Calculate the similarity between the two given strings s and t using the
    # Jaccard index -- the ratio of the number of similar characters in the
    # strings to the total number of (unique) characters.

    return 0 if s.length == 0 && t.length == 0

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
