# frozen_string_literal: true

module Takagi
  module PubSub
    # Registry of publish/subscribe transports (design D6).
    #
    # A transport is registrable by name from outside the library's core, and its name then
    # resolves for every verb. Registration refuses a duplicate name and refuses an entry that
    # declares no capabilities: a transport states what it can do before it can be used, so an
    # unsupported verb/option combination is refused at declaration time instead of silently
    # degraded.
    class TransportRegistry
      class Error < StandardError; end
      class DuplicateNameError < Error; end
      class MissingCapabilitiesError < Error; end
      class TransportNotFoundError < Error; end

      # The capabilities every transported publish/subscribe must declare.
      REQUIRED_CAPABILITIES = %i[
        subscription_confirmed
        ordered_notifications
        carries_reset
        pattern_filters
        max_notification_size
      ].freeze

      @transports = {}
      @mutex = Mutex.new

      class << self
        # Registers a pub/sub transport by name.
        #
        # @param name [Symbol, String] the name the transport resolves under
        # @param transport [Object] an entry responding to `#capabilities` (a Hash)
        # @return [Object] the registered transport
        # @raise [DuplicateNameError] when the name is already registered
        # @raise [MissingCapabilitiesError] when the entry declares no capabilities
        def register(name, transport)
          symbol = name.to_sym
          @mutex.synchronize do
            if @transports.key?(symbol)
              raise DuplicateNameError,
                    "pub/sub transport #{symbol.inspect} is already registered"
            end

            capabilities = transport.respond_to?(:capabilities) ? transport.capabilities : nil
            if capabilities.nil? || capabilities.empty?
              raise MissingCapabilitiesError,
                    "pub/sub transport #{symbol.inspect} declares no capabilities"
            end

            @transports[symbol] = transport
          end
          transport
        end

        # Resolves a registered transport by name.
        #
        # @param name [Symbol, String]
        # @return [Object] the registered entry
        # @raise [TransportNotFoundError] when no transport is registered under the name
        def resolve(name)
          symbol = name.to_sym
          @mutex.synchronize { @transports[symbol] }.tap do |transport|
            unless transport
              raise TransportNotFoundError,
                    "pub/sub transport #{symbol.inspect} is not registered"
            end
          end
        end

        # @param name [Symbol, String]
        # @return [Boolean]
        def registered?(name)
          @mutex.synchronize { @transports.key?(name.to_sym) }
        end

        # @return [Array<Symbol>] registered transport names
        def names
          @mutex.synchronize { @transports.keys }
        end

        # Re-registers the library's default transports (idempotent), so a consumer that
        # cleared the registry - test teardown, a plugin that wants a clean slate - can
        # restore them without knowing their names.
        def register_defaults
          register(:coap_observe, CoapObserve.new) unless registered?(:coap_observe)
        end

        # Clears every registration. Test/plugin teardown only; call {register_defaults} to
        # restore the shipped transports.
        def reset!
          @mutex.synchronize { @transports.clear }
        end
      end
    end
  end
end
