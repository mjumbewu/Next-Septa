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

    vehicles.each do |vehicle|
      # Note that this loop will attempt to calculate lateness for _all_
      # vehicles travelling in both directions, but that one of these
      # directions is going to be the wrong one.  I'm not sure whethere there's
      # a good way for us to know beforehand which direction we want.  Until
      # that's worked out though, we'll get weird results like 45 minutes early
      # because it's a vehicle on a block, but not yet travelling in the right
      # direction.
      nearest_stop = get_nearest_stop(stops, vehicle)
      trips = get_scheduled_departure_times(route_direction, nearest_stop, vehicle, service_id)
      lateness = get_estimated_lateness(trips, vehicle)
      vehicle["lateness"] = lateness if lateness != nil
    end

    render :json => {"bus" => vehicles}
  end

  def get_real_time_locations(route_name)
    # Get the real-time bus location data from SEPTA ad return the response as
    # a JSON-interpreted hash.

    url = "http://www3.septa.org/transitview/bus_route_data/#{route_name}"
    resp = Resourceful.get(url)
    puts "***** The response is..."
    puts url
    puts resp.body

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

    vehicle_lat = Float(vehicle["lat"])
    vehicle_lon = Float(vehicle["lng"])

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

  def get_scheduled_departure_times(route_direction, stop, vehicle, service_id)
    # Get a collection of objects containing Trip data for the trips in the
    # given Vehicle's block, as well as the departure time from the given Stop.

    block_id = vehicle["BlockID"]
    Trip.connection.execute("SELECT trips.*, st.departure_time FROM trips " +
                            "JOIN stop_times st ON st.trip_id = trips.trip_id " +
                            "WHERE st.stop_id = '#{stop.stop_id}' " +
                            "  AND trips.route_id = '#{route_direction.route_id}' " +
                            "  AND trips.direction_id = '#{route_direction.direction_id}' " +
                            "  AND trips.block_id = '#{block_id}'" +
                            "  AND trips.service_id = '#{service_id}'")
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

  def get_estimated_lateness(trips, vehicle)
    # Get an estimate of how late the given vehicle according to the given trip
    # data.
    #
    # NOTE: trips in this case is a collection of objects with trip data as
    # well as a departure time from some stop (for more details, see
    # get_scheduled_departure_time).  This function will use those departure
    # times to determine which is the Trip nearest to the given Vehicle's real-
    # time information.

    puts
    puts "trips #{trips}"

    actual_time = Time.now - Integer(vehicle["Offset"]).minutes

    puts "actual time #{actual_time}"

    nearest_trip = nil
    lateness = nil

    trips.each do |trip|
      next unless same_direction? trip, vehicle

      scheduled_time = interpret_time(trip["departure_time"])

      puts "scheduled time #{scheduled_time}"

      current_lateness = actual_time - scheduled_time

      puts "old lateness #{lateness}"
      puts "current lateness #{current_lateness}"

      if lateness != nil && current_lateness.abs < lateness.abs
        lateness = current_lateness
        nearest_trip = trip
      end
    end

    return nil if lateness == nil
    return (lateness / 60).round
  end

  def same_direction?(trip, vehicle)
    # Return true if the Vehicle is (known to be) travelling in the direction
    # of the Trip.

    similarity_threshold = 0.5

    similarity = jaccard_similarity(trip["trip_headsign"], vehicle["destination"])
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
    s.each_char do |c|
      if t.include? c and !similar_chars.include? c
        similar_chars += c
      end
    end

    # get all the unique characters
    (s+t).each_char do |c|
      if !all_chars.include? c
        all_chars += c
      end
    end

    return similar_chars.length.to_f / all_chars.length.to_f
  end
end
