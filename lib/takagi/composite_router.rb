# frozen_string_literal: true

module Takagi
  # Composite router that routes requests to mounted controllers
  #
  # The CompositeRouter handles prefix-based routing, matching incoming
  # requests to the appropriate controller based on mount paths.
  #
  # @example
  #   router = CompositeRouter.new
  #   router.mount(TelemetryController, '/telemetry')
  #   router.mount(ConfigController, '/config')
  #
  #   handler, params = router.find_route('POST', '/telemetry/data')
  class CompositeRouter
    # Represents a mounted controller with its path and router
    MountedController = Struct.new(:controller_class, :mount_path, :router, :nested_controllers) do
      # Check if this mount handles the given path
      #
      # @param path [String] Request path
      # @return [Boolean] true if path starts with mount_path
      def handles?(path)
        path.start_with?(mount_path)
      end

      # Strip the mount prefix from a path
      #
      # @param path [String] Full request path
      # @return [String] Path with mount prefix removed
      def relative_path(path)
        return path if mount_path == '/'

        path.sub(/^#{Regexp.escape(mount_path)}/, '') || '/'
      end
    end

    def initialize
      @mounted = []
      @logger = Takagi.logger
    end

    # Mount a controller at a specific path
    #
    # @param controller_class [Class] Controller class to mount
    # @param at [String, nil] Mount path (uses controller's mount_path if nil)
    # @return [void]
    #
    # @example
    #   mount(TelemetryController, at: '/telemetry')
    #   mount(TelemetryController) # Uses controller's configured mount_path
    def mount(controller_class, at: nil)
      path = at || controller_class.mount_path

      raise ArgumentError, "Controller #{controller_class} has no mount path" unless path

      # Normalize path
      path = "/#{path}" unless path.start_with?('/')
      path = path.chomp('/') unless path == '/'

      mounted = MountedController.new(
        controller_class,
        path,
        controller_class.router,
        controller_class.nested_controllers
      )

      @mounted << mounted
      @logger.debug "Mounted #{controller_class} at #{path}"

      # Recursively mount nested controllers
      mount_nested_controllers(mounted)
    end

    # Find a route handler for the given method and path
    #
    # @param method [String] HTTP/CoAP method
    # @param path [String] Request path
    # @return [Array(Proc, Hash)] Handler and params, or [nil, {}]
    def find_route(method, path)
      @logger.debug "CompositeRouter: Looking for #{method} #{path}"

      # Find matching mounted controller (longest prefix match)
      mounted = find_mounted_controller(path)

      unless mounted
        @logger.debug "CompositeRouter: No mounted controller for #{path}"
        return [nil, {}]
      end

      # Get relative path within controller
      relative = mounted.relative_path(path)
      @logger.debug "CompositeRouter: Routing to #{mounted.controller_class} with path #{relative}"

      # Find route in controller's router
      mounted.router.find_route(method, relative)
    end

    # The route entry behind {#find_route}, for a caller that needs the route's own declarations
    # rather than its handler. Mirrors {#find_route}'s prefix match and delegates to the mounted
    # controller's own router, so both lookups always agree on which route a request serves.
    #
    # @param method [String] HTTP/CoAP method
    # @param path [String] Request path
    # @return [Takagi::Router::RouteEntry, nil]
    def find_entry(method, path)
      mounted = find_mounted_controller(path)
      return nil unless mounted

      mounted.router.find_entry(method, mounted.relative_path(path))
    end

    # Get all routes from all mounted controllers
    #
    # @return [Array<String>] List of all routes
    def all_routes
      @mounted.flat_map do |mounted|
        mounted.router.all_routes.map do |route|
          method, path = route.split(' ', 2)
          full_path = mounted.mount_path == '/' ? path : File.join(mounted.mount_path, path)
          "#{method} #{full_path}"
        end
      end
    end

    # Get every route entry from all mounted controllers, with mount paths applied
    #
    # @return [Array<Router::RouteEntry>] All route entries
    def route_entries
      @mounted.flat_map do |mounted|
        mounted.router.route_entries.map { |entry| prefixed_entry(entry, mounted.mount_path) }
      end
    end

    # Get link format entries from all mounted controllers
    #
    # @return [Array<Router::RouteEntry>] All link format entries
    def link_format_entries
      route_entries.reject { |entry| entry.metadata[:discovery] }
    end

    def route_count
      @mounted.sum { |mounted| mounted.router.route_count }
    end

    # Get all mounted controllers
    #
    # @return [Array<MountedController>] List of mounted controllers
    def mounted_controllers
      @mounted
    end

    # Find the controller class that handles a given path
    #
    # @param path [String] Request path
    # @return [Class, nil] Controller class or nil if no match
    def find_controller_for_path(path)
      mounted = find_mounted_controller(path)
      mounted&.controller_class
    end

    private

    def prefixed_entry(entry, mount_path)
      full_path = mount_path == '/' ? entry.path : File.join(mount_path, entry.path)
      entry.with_path(full_path)
    end

    # Find the mounted controller that handles a path
    #
    # Uses longest prefix matching to handle nested mounts correctly.
    #
    # @param path [String] Request path
    # @return [MountedController, nil] Matched controller or nil
    def find_mounted_controller(path)
      # Find all controllers that could handle this path
      matches = @mounted.select { |m| m.handles?(path) }

      # Return the one with the longest mount path (most specific)
      matches.max_by { |m| m.mount_path.length }
    end

    # Recursively mount nested controllers
    #
    # @param parent [MountedController] Parent mounted controller
    # @return [void]
    def mount_nested_controllers(parent)
      parent.nested_controllers.each do |child_class|
        # Child's mount path is already resolved to include parent path
        child_mount_path = child_class.mount_path

        next unless child_mount_path

        child_mounted = MountedController.new(
          child_class,
          child_mount_path,
          child_class.router,
          child_class.nested_controllers
        )

        @mounted << child_mounted
        @logger.debug "Mounted nested #{child_class} at #{child_mount_path}"

        # Recursively mount children's children
        mount_nested_controllers(child_mounted)
      end
    end
  end
end
