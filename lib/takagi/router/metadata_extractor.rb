# frozen_string_literal: true

require 'forwardable'

module Takagi
  class Router
    # Handles metadata extraction from route handlers at boot time.
    #
    # Extracted from Router to follow Single Responsibility Principle.
    # Executes route handlers in a special context to capture CoRE Link Format
    # metadata defined via core blocks.
    class MetadataExtractor
      # @param logger [Logger] Logger instance for debugging
      def initialize(logger)
        @logger = logger
      end

      # Executes route handler in metadata extraction mode to capture core block attributes
      # This allows defining metadata inline with the handler for better DX
      #
      # @param entry [RouteEntry] The route entry to extract metadata from
      def extract(entry)
        # Skip metadata extraction for discovery routes to avoid deadlock
        # Discovery routes access the router itself, which would cause a deadlock
        # since we're already holding the routes_mutex. These routes declare
        # their metadata explicitly via the metadata: parameter instead.
        if entry.metadata[:discovery]
          @logger.debug "Skipping metadata extraction for discovery route: #{entry.method} #{entry.path}"
          return
        end

        # Create a mock request object that will be passed to the handler
        mock_request = MetadataExtractionRequest.new

        # Create a special extraction context that uses the entry's AttributeSet directly
        # (This is safe because it runs once at boot time, not during concurrent requests)
        context = MetadataExtractionContext.new(entry, mock_request, {}, entry.receiver)

        # Execute the handler block - it may call core { ... } which updates the attribute_set
        begin
          context.run(entry.block)
        rescue StandardError => e
          # If the handler fails during metadata extraction (e.g., tries to access real data),
          # that's okay - we only care about core blocks which should not throw errors
          @logger.debug "Metadata extraction for #{entry.method} #{entry.path} encountered: #{e.message}"
        end

        # Apply any changes made by core blocks
        entry.attribute_set.apply!
      end

      # Special context for boot-time metadata extraction
      # Uses entry's AttributeSet directly (safe because boot-time is single-threaded)
      #
      # Note: This class inherits from Takagi::Router::RouteContext, but since this file
      # is loaded before RouteContext is defined, we define it as a placeholder here
      # and will reopen it after Router is loaded.
      class MetadataExtractionContext
        include Takagi::Helpers
        extend Forwardable

        attr_reader :request, :params

        # Delegate CoRE attribute methods to @core_attributes
        def_delegators :@core_attributes, :core, :blockwise, :metadata, :attribute
        def_delegators :@core_attributes, :ct, :sz, :title, :obs, :rt, :interface

        def initialize(entry, request, params, receiver)
          @entry = entry
          @request = request
          @params = params
          @receiver = receiver
          # Use entry's AttributeSet directly for boot-time extraction
          # This is safe because metadata extraction runs once at boot time (single-threaded)
          @core_attributes = @entry.attribute_set
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

        # Delegates method calls to the receiver (application instance)
        def method_missing(name, ...)
          if @receiver.respond_to?(name)
            @receiver.public_send(name, ...)
          else
            super
          end
        end

        # Required pair for method_missing
        def respond_to_missing?(name, include_private = false)
          @receiver.respond_to?(name, include_private) || super
        end
      end

      # Mock request object used during metadata extraction
      # Provides minimal interface to prevent errors when handlers are executed at boot time
      class MetadataExtractionRequest
        def to_response(*_args)
          nil # Ignore response generation during metadata extraction
        end

        def method_missing(_name, *_args, &_block)
          nil # Return nil for any method calls to prevent errors
        end

        def respond_to_missing?(_name, _include_private = false)
          true # Pretend to respond to everything
        end
      end
    end
  end
end
