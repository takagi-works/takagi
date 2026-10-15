# frozen_string_literal: true

module Takagi
  module Message
    # Class for outbound message that is coming from server
    class Outbound < Base
      def initialize(code:, payload:, token: nil, message_id: nil, type: CoAP::Registries::MessageType::NON, options: {}, transport: :udp)
        super(nil, transport: transport)  # Call Base.initialize with transport
        @code = coap_method_to_code(code)
        @token = token || ''.b
        @message_id = message_id || rand(0..0xFFFF)
        @type = type
        @options = normalize_options(options)

        # Serialize payload using content-format from options
        @payload = serialize_payload(payload)
      end

      # Serialize payload based on content-format option
      #
      # @param payload [Object] Payload data to serialize
      # @return [String, nil] Serialized binary payload
      def serialize_payload(payload)
        return nil if payload.nil?

        # Already a string? Return as binary
        return payload.b if payload.is_a?(String)

        # Get content-format from options (default to JSON if not specified)
        content_format = @options[CoAP::Registries::Option::CONTENT_FORMAT]
        # Options are stored as arrays, extract first element
        content_format = content_format.first if content_format.is_a?(Array)
        content_format ||= CoAP::Registries::ContentFormat::JSON

        # Use serialization system
        Serialization::Registry.encode(payload, content_format)
      rescue Serialization::UnknownFormatError
        # Fallback to JSON for unknown formats
        @logger.warn "Unknown content-format #{content_format}, falling back to JSON"
        payload.to_json.b
      rescue Serialization::EncodeError => e
        @logger.error "Serialization failed: #{e.message}, falling back to JSON"
        payload.to_json.b
      end

      def to_bytes(transport: nil)
        return ''.b unless @code

        # Use provided transport or fall back to instance variable
        actual_transport = transport || @transport

        with_error_handling do
          log_generation

          # NEW: Use transport registry for encoding
          packet = encode_with_transport(actual_transport)

          log_final_packet(packet)
          packet
        end
      end

      private

      # Encode message using transport registry
      def encode_with_transport(transport_symbol)
        transport_class = case transport_symbol
                          when :tcp
                            Takagi::Network::Registry.get(:tcp)
                          when :udp
                            Takagi::Network::Registry.get(:udp)
                          else
                            Takagi::Network::Registry.get(:udp) # Default to UDP
                          end

        transport_impl = transport_class.new
        transport_impl.encode(self)
      rescue Takagi::Network::Registry::TransportNotFoundError => e
        @logger.error "Transport #{transport_symbol} not found in registry: #{e.message}"
        raise
      end

      def with_error_handling
        yield
      rescue StandardError => e
        @logger.error "To_bytes failed: #{e.message} at #{e.backtrace.first}"
        ''.b
      end

      def log_generation
        @logger.debug "Generating CoAP packet for code #{@code}, payload #{@payload.inspect}, " \
                      "message_id #{@message_id}, token #{@token.inspect}, type #{@type}"
      end

      def log_final_packet(packet)
        @logger.debug "Final CoAP packet: #{packet.inspect}"
      end

      def normalize_options(options)
        return {} unless options.is_a?(Hash)

        @logger.debug "Packet options are: #{options.inspect}"

        options.each_with_object({}) do |(key, value), acc|
          numeric_key = Integer(key)
          values = Array(value)
          acc[numeric_key] = values
        end
      rescue ArgumentError
        {}
      end

    end
  end
end
