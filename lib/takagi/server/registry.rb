# frozen_string_literal: true

module Takagi
  module Server
    # Registry for CoAP server implementations
    #
    # Allows registering different protocol implementations (UDP, TCP, DTLS, QUIC, etc.)
    # without modifying core code. Follows the Open/Closed Principle.
    #
    # Uses Registry::Base for thread-safe storage and consistent API.
    #
    # @example Registering a server
    #   Takagi::Server::Registry.register(:udp, Server::Udp)
    #   Takagi::Server::Registry.register(:tcp, Server::Tcp)
    #
    # @example Building a server
    #   server = Takagi::Server::Registry.build(:tcp, port: 5683, max_connections: 100)
    #
    # @example Adding a custom protocol
    #   class MyCustomServer
    #     def initialize(port:, **options)
    #       # ...
    #     end
    #   end
    #   Takagi::Server::Registry.register(:custom, MyCustomServer)
    class Registry
      extend Takagi::Registry::Base

      # Error raised when protocol is not found
      class ProtocolNotFoundError < Takagi::Registry::Base::NotFoundError; end

      class << self
        # Register a server implementation for a protocol
        #
        # @param protocol [Symbol] Protocol identifier (:udp, :tcp, :dtls, etc.)
        # @param klass [Class] Server class that responds to .new
        # @param metadata [Hash] Optional metadata (description, rfc, etc.)
        #
        # @example
        #   Registry.register(:udp, Server::Udp, rfc: 'RFC 7252')
        #   Registry.register(:tcp, Server::Tcp, rfc: 'RFC 8323')
        def register(protocol, klass, **metadata)
          super(protocol.to_sym, klass, **metadata)
        end

        # Build a server instance for the given protocol
        #
        # @param protocol [Symbol] Protocol identifier
        # @param options [Hash] Options to pass to server constructor
        # @return [Object] Server instance
        # @raise [ProtocolNotFoundError] If protocol is not registered
        #
        # @example
        #   server = Registry.build(:tcp, port: 5683, max_connections: 100)
        def build(protocol, **options)
          klass = get(protocol.to_sym)
          klass.new(**options)
        rescue Takagi::Registry::Base::NotFoundError => e
          raise ProtocolNotFoundError, "Unknown protocol: #{protocol}"
        end

        # Get all registered protocols
        #
        # @return [Array<Symbol>] List of protocol identifiers
        def protocols
          keys
        end
      end
    end
  end
end
