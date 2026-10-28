# frozen_string_literal: true

require_relative 'hooks'

module Takagi
  # Base class for modular controllers with isolated routers.
  #
  # Controllers provide route isolation and nested mounting for modular CoAP services.
  # Concurrency belongs to the SERVICE - the Application's `threads`/`processes`, or the
  # Takagi configuration - never to a controller.
  #
  # @example Simple controller
  #   class TelemetryController < Takagi::Controller
  #     configure do
  #       mount '/telemetry'
  #     end
  #
  #     post '/data' do
  #       # POST /telemetry/data
  #     end
  #   end
  #
  # @example Nested controllers
  #   class ApiController < Takagi::Controller
  #     configure do
  #       mount '/api'
  #       nest DevicesController, UsersController
  #     end
  #   end
  #
  #   class DevicesController < Takagi::Controller
  #     configure do
  #       mount '/devices'
  #     end
  #   end
  class Controller
    # Include reactor management for inline reactor definitions
    extend Base::ReactorManagement

    class << self
      # Get or create the controller's isolated router
      #
      # Each controller has its own Router instance, unlike Takagi::Base
      # which uses a global singleton router.
      #
      # @return [Router] The controller's router instance
      def router
        @router ||= Router.new
      end

      # Get or create the controller's configuration
      #
      # @return [Hash] The controller's configuration hash
      def config
        @config ||= {
          mount_path: nil,
          nested_from: nil,
          nested_controllers: []
        }
      end

      # Configure the controller
      #
      # @yield Block for configuration DSL
      #
      # @example
      #   configure do
      #     mount '/telemetry'
      #   end
      def configure(&block)
        ConfigContext.new(self).instance_eval(&block) if block
      end

      # Register a route with the controller's isolated router
      #
      # @param method [String] HTTP/CoAP method
      # @param path [String] Route path
      # @param metadata [Hash] CoRE Link Format metadata
      # @yield Block to execute for this route
      def add_route(method, path, metadata: {}, &block)
        router.add_route(method, path, metadata: metadata, &block)
      end

      # Dynamically define route registration methods from CoAP::Registries::Method registry
      # Generates: get, post, put, delete, fetch, etc.
      CoAP::Registries::Method.all.each_value do |method_name|
        method_string = method_name.split.first # Extract 'GET' from 'GET'
        method_symbol = method_string.downcase.to_sym

        define_method(method_symbol) do |path, metadata: {}, &block|
          add_route(method_string, path, metadata: metadata, &block)
        end
      end

      # Register a state-carrying topic resource. The block runs once, producing the
      # initial representation; see {Router#topic}.
      #
      # @param path [String] Route path
      # @param metadata [Hash] Additional metadata
      # @yield [emitter] Produces the initial representation
      # @return [Takagi::Topic]
      def topic(path, metadata: {}, &block)
        router.topic(path, metadata: metadata, &block)
      end

      # Get the full mount path for this controller
      #
      # Resolves nested paths if controller is nested from a parent.
      #
      # @return [String, nil] The full mount path
      def mount_path
        path = config[:mount_path]
        return nil unless path

        # If nested from parent, prepend parent's mount path
        if config[:nested_from]
          parent_path = config[:nested_from].mount_path
          return File.join(parent_path, path) if parent_path
        end

        path
      end

      # Check if controller has been configured with a mount path
      #
      # @return [Boolean] true if controller has mount path
      def mounted?
        !config[:mount_path].nil?
      end

      # Get all nested controllers
      #
      # @return [Array<Class>] List of nested controller classes
      def nested_controllers
        config[:nested_controllers]
      end
    end

    # Configuration DSL context
    #
    # Provides methods for configuring controllers within configure blocks.
    class ConfigContext
      def initialize(controller_class)
        @controller = controller_class
      end

      # Set the mount path for this controller
      #
      # @param path [String] The mount path (e.g., '/telemetry')
      # @param nested_from [Class, nil] Optional parent controller
      #
      # @example
      #   mount '/telemetry'
      #   mount '/devices', nested_from: ApiController
      def mount(path, nested_from: nil)
        @controller.config[:mount_path] = path
        @controller.config[:nested_from] = nested_from if nested_from
      end

      # Nest child controllers under this controller
      #
      # @param controllers [Array<Class>] Controller classes to nest
      #
      # @example
      #   nest SensorDataController, MetricsController
      def nest(*controllers)
        @controller.config[:nested_controllers].concat(controllers)

        # Update each nested controller to reference this parent
        controllers.each do |controller|
          controller.config[:nested_from] = @controller
        end
      end
    end
  end
end
