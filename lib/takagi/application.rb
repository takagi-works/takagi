# frozen_string_literal: true

module Takagi
  # Application class for modular controller-based apps
  #
  # Application provides a centralized way to mount and manage multiple
  # controllers, auto-load controller files, and run the server.
  #
  # @example Simple application
  #   class MyApp < Takagi::Application
  #     configure do
  #       load_controllers TelemetryController, ConfigController
  #     end
  #   end
  #
  #   MyApp.run!(port: 5683)
  #
  # @example With auto-loading
  #   class MyApp < Takagi::Application
  #     configure do
  #       auto_load 'app/controllers/**/*_controller.rb'
  #     end
  #   end
  #
  #   MyApp.run!
  class Application
    # Internal controller for CoRE Link Format discovery endpoint
    # Automatically mounted by Application
    class DiscoveryController < Controller
      @@app_router = nil

      def self.app_router=(router)
        @@app_router = router
      end

      def self.app_router
        @@app_router
      end

      configure do
        mount '/.well-known'
      end

      get '/core', metadata: {
        rt: 'core.discovery',
        if: 'core.rd',
        ct: Discovery::CoreLinkFormat::CONTENT_FORMAT,
        discovery: true,
        title: 'Resource Discovery'
      } do |req|
        # Get the composite router from the application
        app_router = DiscoveryController.app_router
        payload = Discovery::CoreLinkFormat.generate(router: app_router, request: req)
        req.to_response(
          '2.05 Content',
          payload,
          options: { CoAP::Registries::Option::CONTENT_FORMAT => Discovery::CoreLinkFormat::CONTENT_FORMAT }
        )
      end
    end

    class << self
      # Get the application's composite router
      #
      # @return [CompositeRouter] The application's router
      def router
        @router ||= CompositeRouter.new
      end

      # Get the application's configuration
      #
      # @return [Hash] Configuration hash
      def config
        @config ||= {
          controllers: [],
          auto_load_patterns: [],
          allocation_mode: :automatic,  # :manual or :automatic
          total_threads: nil             # For automatic mode
        }
      end

      # Configure the application
      #
      # @yield Block for configuration DSL
      #
      # @example
      #   configure do
      #     load_controllers TelemetryController, ConfigController
      #     auto_load 'app/controllers/**/*_controller.rb'
      #   end
      def configure(&block)
        ConfigContext.new(self).instance_eval(&block) if block
      end

      # Load and mount all registered controllers
      #
      # @return [void]
      def load_controllers!
        # Load auto-discovered controllers
        auto_load_controllers! if config[:auto_load_patterns].any?

        # Mount discovery controller first (so it's available at /.well-known/core)
        # Store reference to composite router for discovery endpoint
        DiscoveryController.app_router = router
        router.mount(DiscoveryController)

        # Mount all registered controllers
        config[:controllers].each do |controller_class|
          router.mount(controller_class)
        end
      end

      # Start worker thread pools for all controllers
      #
      # Allocates thread pool resources based on allocation_mode:
      # - :manual - Controllers use their explicit thread_count or profile settings
      # - :automatic - Divides total_threads proportionally by profile weights
      #
      # @return [void]
      def start_all_workers!
        # Use app config first, fall back to global config
        mode = config[:allocation_mode] || Takagi.config.allocation.mode
        total_threads = config[:total_threads] || Takagi.config.allocation.total_threads
        controllers_to_allocate = config[:controllers] + [DiscoveryController]

        # Calculate allocations based on mode
        allocations = Controller::ResourceAllocator.allocate(
          controllers: controllers_to_allocate,
          mode: mode,
          total_threads: total_threads,
          protocol: :tcp  # TCP uses threads, UDP uses processes
        )

        # Validate allocations if automatic mode with total_threads specified
        if mode == :automatic && total_threads
          Controller::ResourceAllocator.validate!(allocations, total_threads: total_threads)
        end

        # Start each controller's thread pool
        allocations.each do |controller_class, allocation|
          threads = allocation[:threads]
          next unless threads && threads > 0

          controller_class.start_workers!(
            threads: threads,
            name: controller_class.name.split('::').last
          )

          Takagi.logger.info "Allocated #{threads} threads to #{controller_class.name} (mode: #{mode})"
        end
      end

      # Shutdown all controller worker thread pools
      #
      # @return [void]
      def shutdown_all_workers!
        all_controllers = config[:controllers] + [DiscoveryController]

        all_controllers.each do |controller_class|
          controller_class.shutdown_workers! if controller_class.workers_running?
        end
      end

      # Run the application server
      #
      # @param options [Hash] Server options (port, protocols, etc.)
      # @return [void]
      #
      # @example
      #   MyApp.run!(port: 5683, protocols: [:udp, :tcp])
      def run!(**options)
        # Load all controllers
        load_controllers!

        # Start controller worker pools
        start_all_workers!

        # Use the composite router instead of global singleton
        options[:router] = router

        # Delegate to server lifecycle (same as Takagi::Base)
        Base::ServerLifecycle.run!(**options)
      end

      # Get all loaded controller classes
      #
      # @return [Array<Class>] List of controller classes
      def controllers
        config[:controllers]
      end

      private

      # Auto-load controllers from file patterns
      #
      # @return [void]
      def auto_load_controllers!
        config[:auto_load_patterns].each do |pattern|
          Dir.glob(pattern).each do |file|
            require_relative file
          end
        end
      end
    end

    # Configuration DSL context for Application
    class ConfigContext
      def initialize(app_class)
        @app = app_class
      end

      # Load specific controller classes
      #
      # @param controllers [Array<Class>] Controller classes to load
      #
      # @example
      #   load_controllers TelemetryController, ConfigController
      def load_controllers(*controllers)
        @app.config[:controllers].concat(controllers)
      end

      # Auto-load controllers from file pattern
      #
      # @param pattern [String] Glob pattern for controller files
      #
      # @example
      #   auto_load 'app/controllers/**/*_controller.rb'
      def auto_load(pattern)
        @app.config[:auto_load_patterns] << pattern
      end

      # Configure worker allocation mode
      #
      # @param mode [Symbol] :manual or :automatic
      # @param threads [Integer] Total threads for automatic mode
      #
      # @example Manual allocation (controllers specify their own thread counts)
      #   allocation :manual
      #
      # @example Automatic allocation (divide 40 threads among controllers)
      #   allocation :automatic, threads: 40
      def allocation(mode, threads: nil)
        unless [:manual, :automatic].include?(mode)
          raise ArgumentError, "Invalid allocation mode: #{mode}. Use :manual or :automatic"
        end

        if mode == :automatic && threads.nil?
          raise ArgumentError, "Automatic allocation requires threads: parameter"
        end

        @app.config[:allocation_mode] = mode
        @app.config[:total_threads] = threads
      end
    end
  end
end
