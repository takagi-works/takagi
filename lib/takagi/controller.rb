# frozen_string_literal: true

require_relative 'controller/thread_pool'
require_relative 'controller/resource_allocator'

module Takagi
  # Base class for modular controllers with isolated routers
  #
  # Controllers provide route isolation, independent process pools, and
  # nested mounting capabilities for building scalable CoAP applications.
  #
  # @example Simple controller
  #   class TelemetryController < Takagi::Controller
  #     configure do
  #       mount '/telemetry'
  #       profile :high_throughput
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
  #       profile :high_throughput
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
          nested_controllers: [],
          profile: nil,
          processes: nil,
          threads: nil
        }
      end

      # Configure the controller
      #
      # @yield Block for configuration DSL
      #
      # @example
      #   configure do
      #     mount '/telemetry'
      #     profile :high_throughput
      #     set :processes, 16
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

      # Register an observable route
      #
      # @param path [String] Route path
      # @param metadata [Hash] Additional metadata
      # @yield Block to execute for this route
      def observable(path, metadata: {}, &block)
        observable_metadata = { obs: true, rt: 'core#observable', if: 'takagi.observe' }
        add_route('OBSERVE', path, metadata: observable_metadata.merge(metadata), &block)
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

      # Get the load profile name
      #
      # @return [Symbol, nil] Profile name or nil
      def profile_name
        config[:profile]
      end

      # Get the effective process count
      #
      # Uses explicit :processes config, falls back to profile, or nil.
      #
      # @return [Integer, nil] Number of processes
      def process_count
        config[:processes] || profile_config[:processes]
      end

      # Get the effective thread count
      #
      # Uses explicit :threads config, falls back to profile, or nil.
      #
      # @return [Integer, nil] Number of threads
      def thread_count
        config[:threads] || profile_config[:threads]
      end

      # Get or create the controller's thread pool
      #
      # Lazy initialization: creates pool on first access if not already started.
      # This allows reactors to share the controller's pool automatically.
      #
      # @return [ThreadPool] Thread pool instance
      def thread_pool
        @thread_pool ||= begin
          Takagi.logger.debug "Lazy-initializing thread pool for #{name}"
          start_workers!
        end
      end

      # Start the controller's worker thread pool
      #
      # @param threads [Integer] Number of threads to allocate
      # @param name [String] Pool name (defaults to controller class name)
      # @return [ThreadPool] The started thread pool
      def start_workers!(threads: nil, name: nil)
        threads ||= thread_count || 4  # Default to 4 threads
        name ||= self.name.split('::').last  # e.g., "IngressController"

        @thread_pool = ThreadPool.new(size: threads, name: name)
        Takagi.logger.info "Started worker pool for #{name} with #{threads} threads"
        @thread_pool
      end

      # Shutdown the controller's worker thread pool
      def shutdown_workers!
        return unless @thread_pool

        Takagi.logger.info "Shutting down worker pool for #{name}"
        @thread_pool.shutdown
        @thread_pool = nil
      end

      # Schedule a job to run in the controller's thread pool
      #
      # @yield Block to execute in worker thread
      # @raise [ThreadPoolError] if thread pool not started
      def schedule(&block)
        unless @thread_pool
          error = Errors::ThreadPoolError.not_started(name)
          raise error
        end

        @thread_pool.schedule(&block)
      end

      # Check if the controller's thread pool is running
      #
      # @return [Boolean] true if thread pool is active
      def workers_running?
        @thread_pool && !@thread_pool.shutdown?
      end

      private

      # Get the profile configuration
      #
      # @return [Hash] Profile configuration or empty hash
      def profile_config
        return {} unless config[:profile]

        Profiles.get(config[:profile]) || {}
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

      # Set a load profile for this controller
      #
      # @param name [Symbol] Profile name
      #
      # @example
      #   profile :high_throughput
      def profile(name)
        unless Profiles.exists?(name)
          error = Errors::ConfigurationError.invalid_profile(name, Profiles.available)
          raise ArgumentError, error.message
        end

        @controller.config[:profile] = name
      end

      # Set the number of threads for this controller
      #
      # @param count [Integer] Number of threads
      #
      # @example
      #   threads 8
      def threads(count)
        unless count.is_a?(Integer) && count.positive?
          error = Errors::ValidationError.invalid_thread_count(count)
          raise ArgumentError, error.message
        end

        @controller.config[:threads] = count
      end

      # Set a configuration value
      #
      # @param key [Symbol] Configuration key
      # @param value [Object] Configuration value
      #
      # @example
      #   set :processes, 16
      #   set :threads, 4
      def set(key, value)
        @controller.config[key] = value
      end
    end
  end
end
