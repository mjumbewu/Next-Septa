class RouteTypeController < ApplicationController  
  def index
    create_headers
    type = ROUTE_TYPES[params[:route_type]]
    @route_types = Route.where("route_type = " + type.to_s).order("lpad(route_short_name, 6, '0')")
    @first_letter = ''
  end
end
