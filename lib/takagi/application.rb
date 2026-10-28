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
  #       threads 8
  #       processes 2
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
    # The service lifecycle an Application shares with Base: boot the configuration, build one
    # transport per protocol with the SERVICE's own router and stack, announce the service, and
    # serve. Plugin management comes with it, because `enable_plugins!` is part of that lifecycle.
    extend Base::ServerLifecycle
    extend Base::PluginManagement

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
          profile: nil,
          threads: nil,
          processes: nil,
          port: nil,
          protocols: nil,
          bind_address: nil,
          max_connections: nil,
          protocol_settings: nil
        }
      end

      # The concurrency and transport settings this SERVICE carries. A profile stands in for
      # anything not written explicitly; the lifecycle falls back to Takagi.config for what is
      # still absent here.
      #
      # @return [Hash{Symbol => Object}]
      def service_settings
        profile = config[:profile] ? (Profiles.get(config[:profile]) || {}) : {}
        {
          threads: config[:threads] || profile[:threads],
          processes: config[:processes] || profile[:processes],
          port: config[:port],
          protocols: config[:protocols],
          bind_address: config[:bind_address],
          max_connections: config[:max_connections],
          protocol_settings: config[:protocol_settings]
        }.compact
      end

      # The middleware stack this service runs: its OWN stack, resolving through the composite
      # router. The shared process stack resolves through `Takagi::Router.instance`, which knows
      # none of the mounted controllers, so an Application served through it would answer 4.04.
      #
      # @return [MiddlewareStack]
      def middleware_stack
        @middleware_stack ||= Takagi::MiddlewareStack.build(router: router)
      end

      # Adds a middleware to this application's stack.
      #
      # @param middleware [Object] Middleware instance responding to #call
      # @return [void]
      def use(middleware)
        middleware_stack.use(middleware)
      end

      # The controller that holds routes registered directly on the application - the surface
      # `MyApp.get '/health'` and a plugin's route registration both use. It mounts at `/`, so a
      # controller's own mount path always wins the longest-prefix match.
      #
      # @return [Class] an anonymous Controller subclass
      def root_controller
        @root_controller ||= Class.new(Controller).tap { |controller| controller.configure { mount '/' } }
      end

      CoAP::Registries::Method.all.each_value do |method_name|
        method_string = method_name.split.first
        method_symbol = method_string.downcase.to_sym

        define_method(method_symbol) do |path, metadata: {}, &block|
          root_controller.add_route(method_string, path, metadata: metadata, &block)
        end
      end

      # Registers a state-carrying topic resource directly on the application. The block
      # runs once, producing the initial representation; see {Router#topic}.
      #
      # @param path [String] Resource path
      # @param metadata [Hash] Additional CoRE metadata
      # @return [Takagi::Topic]
      def topic(path, metadata: {}, &block)
        root_controller.topic(path, metadata: metadata, &block)
      end

      # Configure the application
      #
      # @yield Block for configuration DSL
      #
      # @example
      #   configure do
      #     load_controllers TelemetryController, ConfigController
      #     auto_load 'app/controllers/**/*_controller.rb'
      #     threads 8
      #     processes 2
      #   end
      def configure(&block)
        ConfigContext.new(self).instance_eval(&block) if block
      end

      # Load and mount all registered controllers. Idempotent: the lifecycle calls it at boot and
      # a caller may already have done so, and mounting twice would duplicate every route.
      #
      # @return [void]
      def load_controllers!
        return if @controllers_loaded

        # Load auto-discovered controllers
        auto_load_controllers! if config[:auto_load_patterns].any?

        # Mount discovery controller first (so it's available at /.well-known/core)
        # Store reference to composite router for discovery endpoint
        DiscoveryController.app_router = router
        router.mount(DiscoveryController)

        # Application-level routes live at the root, under every controller's own mount.
        router.mount(root_controller)

        # Mount all registered controllers
        config[:controllers].each do |controller_class|
          router.mount(controller_class)
        end

        @controllers_loaded = true
      end

      # Prepares the service before the lifecycle builds any transport: the controllers are
      # mounted HERE, in the process that boots, so every transport resolves through the
      # composite router from its first request.
      #
      # @param config_path [String] Path to configuration file
      # @return [void]
      def boot!(config_path: 'config/takagi.yml')
        super
        load_controllers!
      end

      # Spawns the application's servers in background threads, with its controllers already
      # loaded. Concurrency comes from this service's settings (`threads`/`processes`, a profile,
      # or Takagi.config), never from a controller.
      #
      # @param port [Integer, nil] Port to bind to (uses the service config if nil)
      # @param protocols [Array<Symbol>, nil] Protocols to enable (uses the service config if nil)
      # @return [Server, Multi] The spawned server instance
      def spawn!(port: nil, protocols: nil)
        load_controllers!
        super
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

      # Set the service's concurrency and transport settings. A profile supplies defaults; an
      # explicit `threads`/`processes` always wins over it.
      #
      # @example
      #   profile :high_throughput
      #   threads 8
      #   processes 2
      #   port 5683
      #   protocols :udp, :tcp
      #   protocol_settings tcp: { max_connections: 200 }
      def profile(name)
        unless Profiles.exists?(name)
          error = Errors::ConfigurationError.invalid_profile(name, Profiles.available)
          raise ArgumentError, error.message
        end

        @app.config[:profile] = name
      end

      def threads(count)
        raise ArgumentError, Errors::ValidationError.invalid_thread_count(count).message unless count.is_a?(Integer) && count.positive?

        @app.config[:threads] = count
      end

      def processes(count)
        raise ArgumentError, Errors::ValidationError.invalid_process_count(count).message unless count.is_a?(Integer) && count.positive?

        @app.config[:processes] = count
      end

      def port(value)
        number = Integer(value)
        raise ArgumentError, "port must be in 0..65535: #{value.inspect}" unless (0..65_535).cover?(number)

        @app.config[:port] = number
      end

      def protocols(*list)
        values = list.flatten.map(&:to_sym)
        raise ArgumentError, 'at least one protocol is required' if values.empty?

        @app.config[:protocols] = values
      end

      def bind_address(value)
        @app.config[:bind_address] = value.to_s
      end

      def max_connections(count)
        raise ArgumentError, "max_connections must be a positive Integer: #{count.inspect}" unless count.is_a?(Integer) && count.positive?

        @app.config[:max_connections] = count
      end

      def protocol_settings(settings)
        raise ArgumentError, "protocol_settings must be a Hash: #{settings.inspect}" unless settings.is_a?(Hash)

        @app.config[:protocol_settings] = settings.to_h do |protocol, options|
          [protocol.to_sym, (options || {}).to_h { |key, value| [key.to_sym, value] }]
        end
      end

      # The `set` spelling for parity with the rest of the DSL.
      def set(key, value)
        case key.to_sym
        when :threads then threads(value)
        when :processes then processes(value)
        when :port then port(value)
        when :protocols then protocols(value)
        when :bind_address then bind_address(value)
        when :max_connections then max_connections(value)
        when :protocol_settings then protocol_settings(value)
        else raise ArgumentError, "unknown service setting #{key.inspect}"
        end
      end
    end
  end
end
