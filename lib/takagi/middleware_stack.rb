# frozen_string_literal: true

require 'singleton'
require_relative 'hooks'

module Takagi
  # Middleware stack for processing CoAP requests
  #
  # Provides a Rack-style middleware chain for request/response processing.
  # Middleware can be configured via Takagi.config.middleware or programmatically.
  #
  # @example Programmatic configuration
  #   stack = MiddlewareStack.instance
  #   stack.use(Takagi::Middleware::Logging.new)
  #   stack.use(Takagi::Middleware::Caching.new)
  #
  # @example YAML configuration (takagi.yml)
  #   middleware:
  #     enabled: true
  #     stack:
  #       - Logging
  #       - name: Caching
  #         options:
  #           ttl: 300
  class MiddlewareStack
    include Singleton

    attr_reader :middlewares, :router

    def initialize
      @logger = Takagi.logger
      @middlewares = []
      @router = Takagi::Router.instance
      @config_loaded = false
    end

    # Load middleware from Takagi configuration
    # This is called lazily on first request to ensure config is loaded
    def load_from_config
      return if @config_loaded
      return unless defined?(Takagi.config)

      @config_loaded = true

      # Check if middleware is globally disabled
      return unless Takagi.config.middleware.enabled

      # Load middleware stack from configuration
      Takagi.config.middleware.stack.each do |middleware_config|
        load_middleware(middleware_config)
      end

      @logger.debug "Loaded #{@middlewares.size} middleware(s)" if @middlewares.any?
    rescue StandardError => e
      @logger.error "Failed to load middleware configuration: #{e.message}"
      @logger.debug e.backtrace.join("\n")
    end

    # Adds a new middleware to the stack
    # @param middleware [Object] Middleware instance that responds to `call`
    def use(middleware)
      @middlewares << middleware
    end

    # Processes the request through the middleware stack and routes it
    # @param request [Takagi::Message::Inbound] Incoming request object
    # @return [Takagi::Message::Outbound] The final processed response
    def call(request)
      # Lazily load configuration on first request
      load_from_config unless @config_loaded
      Takagi::Hooks.emit(:middleware_before_call, request: request)

      # Define the core application logic (routing)
      app = lambda do |req|
        block, params = @router.find_route(req.method.to_s, req.uri.path)
        if block
          block.call(req, params)
        else
          req.to_response('4.04 Not Found', { error: 'not found' })
        end
      end

      # Build middleware chain (reverse order for proper execution)
      response = @middlewares.reverse.reduce(app) do |next_middleware, middleware|
        ->(req) { middleware.call(req, &next_middleware) }
      end.call(request)

      Takagi::Hooks.emit(:middleware_after_call, request: request, response: response)
      response
    end

    # Clear all middleware (useful for testing)
    def clear
      @middlewares.clear
    end

    # Reset configuration loaded flag (useful for testing)
    def reset!
      @middlewares.clear
      @config_loaded = false
    end

    private

    # Load and instantiate a middleware from configuration
    # @param config [Hash] Middleware configuration with :name and :options
    def load_middleware(config)
      middleware_name = config[:name]
      options = config[:options] || {}

      # Resolve middleware class
      klass = resolve_middleware_class(middleware_name)
      return unless klass

      # Instantiate middleware with options
      middleware = instantiate_middleware(klass, options)
      use(middleware) if middleware

      @logger.debug "Loaded middleware: #{middleware_name} with options: #{options.inspect}"
    rescue StandardError => e
      @logger.warn "Failed to load middleware #{middleware_name}: #{e.message}"
      @logger.debug e.backtrace.join("\n")
    end

    # Resolve middleware class from name
    # Supports both short names (e.g., "Logging") and full names (e.g., "MyApp::CustomMiddleware")
    def resolve_middleware_class(name)
      # Try Takagi::Middleware namespace first
      begin
        return Object.const_get("Takagi::Middleware::#{name}")
      rescue NameError
        # Not in Takagi::Middleware namespace
      end

      # Try as a full class name
      begin
        Object.const_get(name)
      rescue NameError
        @logger.warn "Middleware class not found: #{name}"
        nil
      end
    end

    # Instantiate middleware with or without options
    # @param klass [Class] Middleware class
    # @param options [Hash] Options to pass to initializer
    def instantiate_middleware(klass, options)
      if options.empty?
        # Try to instantiate without arguments
        klass.new
      else
        # Pass options to initializer
        # Support both keyword arguments and hash argument
        begin
          klass.new(**options)
        rescue ArgumentError
          # Fall back to positional hash argument
          klass.new(options)
        end
      end
    rescue ArgumentError => e
      @logger.warn "Failed to instantiate #{klass}: #{e.message}. Trying without options..."
      klass.new
    end
  end
end
