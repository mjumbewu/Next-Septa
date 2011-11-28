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
      vehicle["lateness"] = lateness
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
    lateness = 1000000000000000000000000

    trips.each do |trip|
      scheduled_time = interpret_time(trip["departure_time"])

      puts "scheduled time #{scheduled_time}"

      current_lateness = actual_time - scheduled_time

      puts "old lateness #{lateness}"
      puts "current lateness #{current_lateness}"

      if current_lateness.abs < lateness.abs
        lateness = current_lateness
        nearest_trip = trip
      end
    end

    return (lateness / 60).round
  end

  def levenshtein_distance(s, t)
    # The following dynamic programming implementation is adapted from the pseudo-
    # code on the Wikipedia page:
    #
    # http://en.wikipedia.org/wiki/Levenshtein_distance#Computing_Levenshtein_distance

    # s is a string of length m
    # t is a string of length n

    # for all i and j, d[i,j] will hold the Levenshtein distance between
    # the first i characters of s and the first j characters of t;
    # note that d has (m+1)x(n+1) values
    d = []

    m = s.length
    (m+1).times do |i|
      d[i] = [i]  # the distance of any first string to an empty second string
    end

    n = t.length
    (n+1).times do |j|
      d[0][j] = j  # the distance of any second string to an empty first string
    end

    (n+1).times do |j|
      next if j == 0

      (m+1).times do |i|
        next if i == 0

        if s[i-1] == t[j-1]
          d[i][j] = d[i-1][j-1]        # no operation required
        else
          d[i][j] = [
                      d[i-1][j] + 1,   # a deletion
                      d[i][j-1] + 1,   # an insertion
                      d[i-1][j-1] + 1  # a substitution
                    ].min
        end

      end  # m.times
    end  # n.times

    return d[m][n]
  end

  def levenshtein_differentness(s, t)
    # Calculate the normalized differentness of two strings based on their
    # levelshtein distance and the length of the longer string.  The value is
    # between 0 (the lower bound on the L-distance) and 1 (since the upper
    # bound on L-distance is the length of the longer string).
    #
    # Two completely different strings of the same length (no characters in
    # common) will have a L-diff of 1.  If one of the strings is empty, the
    # L-diff will be 1.

    return 0 if s.length == 0 && t.length == 0

    dist = levenshtein_distance(s, t)
    return dist / [s.length, t.length].max.to_f
  end
end
