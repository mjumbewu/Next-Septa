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
      nearest_stop = get_nearest_stop(stops, vehicle)
      trips = get_scheduled_departure_times(route_direction, nearest_stop, vehicle, service_id)
      lateness = get_estimated_lateness(trips, vehicle)
      vehicle["lateness"] = lateness
    end

    render :json => {"bus" => vehicles}
  end

  def get_real_time_locations(route_name)
    url = "http://www3.septa.org/transitview/bus_route_data/#{route_name}"
    resp = Resourceful.get(url)
    puts "***** The response is..."
    puts url
    puts resp.body
    return ActiveSupport::JSON.decode(resp.body)["bus"]
  end

  def get_route_direction(route_id, direction_id)
    RouteDirection.select("*")
      .where("route_id = '#{route_id}' AND direction_id = '#{direction_id}'")
      .first
  end

  def get_stops(route_direction)
    Stop.select("*")
      .joins("JOIN simplified_stops ss ON stops.stop_id = ss.stop_id")
      .where("ss.route_id = '#{route_direction.route_id}' AND ss.direction_id = '#{route_direction.direction_id}'")
  end

  def get_nearest_stop(stops, vehicle)
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
    time_pieces = time_string.split(':')

    now = Time.now
    time = Time.new(now.year, now.month, now.day, time_pieces[0].to_i % 24, time_pieces[1].to_i, time_pieces[2].to_i)
    if time < (now - 6.hours)
      time += 1.day
    end

    return time
  end

  def get_estimated_lateness(trips, vehicle)
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
end
