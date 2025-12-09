# frozen_string_literal: true

require 'forwardable'
require_relative 'core/attribute_set'
require_relative 'helpers'
require_relative 'router/route_matcher'
require_relative 'router/metadata_extractor'
require_relative 'hooks'

module Takagi
  class Router
    DEFAULT_CONTENT_FORMAT = Takagi::CoAP::Registries::ContentFormat::JSON

    class << self
      # Global singleton instance for backward compatibility with Takagi::Base
      # New code should create Router instances directly
      #
      # @return [Router] The global router instance
      def instance
        @instance ||= new
      end

      # Reset the global instance (primarily for testing)
      #
      # @return [void]
      def reset!
        @instance = nil
      end
    end

    # Represents a registered route with its handler and CoRE Link Format metadata
    class RouteEntry
      attr_reader :method, :path, :block, :receiver, :attribute_set

      def initialize(method:, path:, block:, metadata: {}, receiver: nil)
        @method = method
        @path = path
        @block = block
        @receiver = receiver
        @attribute_set = Core::AttributeSet.new(metadata)
      end

      # Returns the underlying metadata hash for backward compatibility
      def metadata
        @attribute_set.metadata
      end

      # Configure CoRE Link Format attributes using DSL block
      #
      # @example
      #   entry.configure_attributes do
      #     rt 'sensor'
      #     obs true
      #     ct 'application/json'
      #   end
      def configure_attributes(&block)
        @attribute_set.core(&block)
        @attribute_set.apply!
      end

      # Support for dup operation (used in discovery)
      def initialize_copy(original)
        super
        @attribute_set = Core::AttributeSet.new(original.metadata.dup)
      end
    end

    # Provides the execution context for route handlers, exposing helper
    # methods for configuring CoRE Link Format attributes via a small DSL.
    class RouteContext
      extend Forwardable
      include Takagi::Helpers

      attr_reader :request, :params

      # Delegate CoRE attribute methods to @core_attributes
      def_delegators :@core_attributes, :core, :metadata, :attribute
      def_delegators :@core_attributes, :ct, :sz, :title, :obs, :rt, :interface

      # Aliases for common methods
      alias content_format ct
      alias observable obs
      alias if_ interface

      def initialize(entry, request, params, receiver)
        @entry = entry
        @request = request
        @params = params
        @receiver = receiver
        # Create a fresh AttributeSet for this request to avoid cross-request state sharing
        # Initialize it with a copy of the entry's current metadata
        @core_attributes = Core::AttributeSet.new(@entry.metadata.dup)
      end

      def run(block)
        return unless block

        args = case block.arity
               when 0 then []
               when 1 then [request]
               else
                 [request, params]
               end
        args = [request, params] if block.arity.negative?

        # Support halt for early returns
        result = catch(:halt) do
          instance_exec(*args, &block)
        end

        result
      ensure
        @core_attributes.apply!
      end

      private

      # Returns content-format(s) declared for this route (CoRE `ct` metadata).
      # Used by response helpers to align runtime negotiation with discovery data.
      def core_content_formats
        formats = @entry&.metadata&.[](:ct)
        Array(formats).compact unless formats.nil?
      end

      # Delegates method calls to the receiver (application instance)
      # This allows route handlers to call application methods within their blocks
      # Example: get '/users' do; fetch_users; end - calls application's fetch_users method
      def method_missing(name, ...)
        if @receiver.respond_to?(name)
          @receiver.public_send(name, ...)
        else
          super
        end
      end

      # Required pair for method_missing to properly support respond_to?
      def respond_to_missing?(name, include_private = false)
        @receiver.respond_to?(name, include_private) || super
      end
    end

    def initialize
      @routes = {}
      @routes_mutex = Mutex.new # Protects route modifications in multithreaded environments
      @logger = Takagi.logger
      @route_matcher = RouteMatcher.new(@logger)
      @metadata_extractor = MetadataExtractor.new(@logger)
    end

    # Registers a new route for a given HTTP method and path
    # @param method [String] The HTTP method (GET, POST, etc.)
    # @param path [String] The URL path, can include dynamic segments like `:id`
    # @param block [Proc] The handler to be executed when the route is matched
    def add_route(method, path, metadata: {}, &block)
      @routes_mutex.synchronize do
        entry = build_route_entry(method, path, metadata, block)
        @routes["#{method} #{path}"] = entry
        @logger.debug "Add new route: #{method} #{path}"

        # Extract metadata from core blocks inside the handler
        extract_metadata_from_handler(entry) if block

        Takagi::Hooks.emit(
          :router_route_added,
          method: method,
          path: path,
          entry: entry
        )
      end
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

    # Registers a OBSERVE route
    # @param path [String] The URL path
    # @param block [Proc] The handler function
    def observable(path, metadata: {}, &block)
      observable_metadata = { obs: true, rt: 'core#observable', if: 'takagi.observe' }
      add_route('OBSERVE', path, metadata: observable_metadata.merge(metadata), &block)
    end

    def all_routes
      @routes.values.map { |entry| "#{entry.method} #{entry.path}" }
    end

    def find_observable(path)
      @routes.values.find { |entry| entry.method == 'OBSERVE' && entry.path == path }
    end

    # Finds a registered route for a given method and path
    # @param method [String] HTTP method
    # @param path [String] URL path
    # @return [Proc, Hash] The matching handler and extracted parameters
    def find_route(method, path)
      @routes_mutex.synchronize do
        @logger.debug "Routes: #{@routes.inspect}"
        @logger.debug "Looking for route: #{method} #{path}"
        entry = @routes["#{method} #{path}"]
        params = {}

        return wrap_block(entry), params if entry

        @logger.debug '[Debug] Find dynamic route'
        entry, params = match_dynamic_route(method, path)

        return wrap_block(entry), params if entry

        [nil, {}]
      end
    end

    def link_format_entries
      @routes_mutex.synchronize do
        @routes.values.reject { |entry| entry.metadata[:discovery] }.map(&:dup)
      end
    end

    # Applies CoRE metadata outside the request cycle. Useful for boot time
    # configuration where the DSL block does not have a live request object.
    def configure_core(method, path, &block)
      return unless block

      @routes_mutex.synchronize do
        entry = @routes["#{method} #{path}"]
        unless entry
          @logger.warn "configure_core skipped: #{method} #{path} not registered"
          return
        end

        entry.configure_attributes(&block)
      end
    end

    private

    def wrap_block(entry)
      block = entry&.block
      return nil unless block

      lambda do |req, params = {}|
        context = RouteContext.new(entry, req, params, entry.receiver)
        context.run(block)
      end
    end

    # Matches dynamic routes that contain parameters (e.g., `/users/:id`)
    # Delegates to RouteMatcher for the actual matching logic
    # @param method [String] HTTP method
    # @param path [String] Request path
    # @return [Array(RouteEntry, Hash)] Matched route entry and extracted parameters
    def match_dynamic_route(method, path)
      @route_matcher.match(@routes, method, path)
    end

    def build_route_entry(method, path, metadata, block)
      RouteEntry.new(
        method: method,
        path: path,
        block: block,
        metadata: normalize_metadata(method, path, metadata),
        receiver: block&.binding&.receiver
      )
    end

    # Normalizes route metadata with sensible defaults for CoRE Link Format
    #
    # @param method [String] HTTP-like method (GET, POST, OBSERVE, etc.)
    # @param path [String] Route path
    # @param metadata [Hash, nil] User-provided metadata
    # @return [Hash] Normalized metadata with defaults applied
    def normalize_metadata(method, path, metadata)
      normalized = (metadata || {}).transform_keys(&:to_sym)
      normalized[:rt] ||= default_resource_type(method)
      normalized[:if] ||= default_interface(method)
      normalized[:ct] = DEFAULT_CONTENT_FORMAT unless normalized.key?(:ct)
      normalized[:title] ||= "#{method} #{path}"
      normalized
    end

    def default_resource_type(method)
      method == 'OBSERVE' ? 'core#observable' : 'core#endpoint'
    end

    def default_interface(method)
      method == 'OBSERVE' ? 'takagi.observe' : "takagi.#{method.downcase}"
    end

    # Executes route handler in metadata extraction mode to capture core block attributes
    # Delegates to MetadataExtractor for the actual extraction logic
    # @param entry [RouteEntry] The route entry to extract metadata from
    def extract_metadata_from_handler(entry)
      @metadata_extractor.extract(entry)
    end
  end
end
