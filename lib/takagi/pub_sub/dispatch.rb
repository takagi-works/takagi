# frozen_string_literal: true

module Takagi
  module PubSub
    # The verb dispatch surface for registered pub/sub transports (reactor-interactions:
    # "Transports are registered, not hard-coded" and "Unsupported combinations are refused
    # when declared").
    #
    # A request names a transport, one of the vocabulary verbs, and the options it wants.
    # The name resolves through {TransportRegistry}, the verb through
    # {ReactorInteraction}, and every requested option is then refused unless the
    # transport's declared capabilities can honour it - the refusal names the capability
    # it cannot provide, so an unsupported combination fails loudly at declaration time
    # instead of being accepted and silently degraded.
    module Dispatch
      # Error raised when a request asks for something the transport declines.
      class UnsupportedCapabilityError < StandardError; end

      # Error raised when the transport does not implement the requested verb.
      class UnsupportedVerbError < StandardError; end

      # Option keys that request a pattern filter; every one is gated on the transport's
      # `:pattern_filters` capability.
      PATTERN_OPTIONS = %i[pattern filter wildcard].freeze

      module_function

      # Resolves and validates one verb request and dispatches it to the transport.
      #
      # @param transport_name [Symbol, String] a registered transport name
      # @param verb [Symbol, String] a vocabulary verb or its alias spelling
      # @param options [Hash] the requested options, validated against the declaration
      # @return [Object] the transport's answer
      # @raise [TransportRegistry::TransportNotFoundError] when the name is not registered
      # @raise [ReactorInteraction::UnknownNameError] when the verb is not in the vocabulary
      # @raise [UnsupportedCapabilityError] when the options need a capability the transport
      #   does not declare
      # @raise [UnsupportedVerbError] when the transport does not implement the verb
      def dispatch(transport_name, verb, options: {})
        transport = TransportRegistry.resolve(transport_name)
        verb_symbol = ReactorInteraction.resolve(verb)
        validate!(transport_name, transport, verb_symbol, options: options)

        unless transport.respond_to?(verb_symbol)
          raise UnsupportedVerbError,
                "transport #{transport_name.inspect} does not implement verb #{verb_symbol.inspect}"
        end

        transport.public_send(verb_symbol, options: options)
      end

      # Validates a verb request against a transport's declared capabilities without
      # dispatching it, for a declaration that only wants the refusal.
      #
      # @param transport_name [Symbol, String]
      # @param transport [Object] a registered transport entry
      # @param verb [Symbol]
      # @param options [Hash]
      # @return [void]
      # @raise [UnsupportedCapabilityError] when the options need a capability the transport
      #   does not declare
      def validate!(transport_name, transport, _verb_symbol, options: {})
        capabilities = capability_hash(transport)

        PATTERN_OPTIONS.each do |key|
          next unless options.key?(key)
          next if capabilities[:pattern_filters]

          raise UnsupportedCapabilityError,
                "transport #{transport_name.inspect} cannot honour #{key.inspect}: it does " \
                'not declare the :pattern_filters capability'
        end

        return unless options.key?(:max_notification_size)
        return unless capabilities[:max_notification_size]
        return if options[:max_notification_size].to_i <= capabilities[:max_notification_size]

        raise UnsupportedCapabilityError,
              "transport #{transport_name.inspect} cannot honour :max_notification_size of " \
              "#{options[:max_notification_size]}: it declares at most " \
              "#{capabilities[:max_notification_size]} bytes"
      end

      def capability_hash(transport)
        transport.respond_to?(:capabilities) ? transport.capabilities : {}
      end
      private_class_method :capability_hash
    end
  end
end
