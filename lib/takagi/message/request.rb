# frozen_string_literal: true

require 'securerandom'

module Takagi
  module Message
    # Encodes outbound CoAP request envelopes used when observing remote peers.
    class Request < Base
      attr_reader :message_id

      def initialize(method:, uri:, payload: nil, token: nil, **options)
        super()
        @method = method
        @uri = uri
        @token = token || SecureRandom.hex(4)
        @observe = options.fetch(:observe, nil)
        @message_id = options.fetch(:message_id) { rand(0..0xFFFF) }
        @payload = payload
      end

      def to_bytes
        version = Takagi::CoAP::VERSION
        type = CoAP::Registries::MessageType::CON # Confirmable
        token_length = @token.bytesize
        # Use CoAP registry to convert method to code
        code = CoAP::CodeHelpers.to_numeric(@method)
        ver_type_token = ((version << 6) | (type << 4) | token_length)
        header = [ver_type_token, code, @message_id].pack('CCn')

        options = encode_options
        token_part = @token.b
        payload_part = if @payload.nil? || @payload == ''
                         ''.b
                       elsif @payload.is_a?(String)
                         "\xFF".b + @payload.b
                       else
                         "\xFF".b + @payload.to_json.b
                       end

        packet = (header + token_part + options + payload_part).b

        Takagi.logger.debug "Generated Request packet: #{packet.inspect}"
        packet
      end

      private

      def encode_options
        last_option_number = 0
        encoded = []

        # Observe option must be first for correct delta encoding
        unless @observe.nil?
          encoded << encode_option(CoAP::Registries::Option::OBSERVE, [@observe].pack('C'), last_option_number)
          last_option_number = CoAP::Registries::Option::OBSERVE
        end

        # Encode URI path segments
        @uri.path.split('/').reject(&:empty?).each do |segment|
          encoded << encode_option(CoAP::Registries::Option::URI_PATH, segment, last_option_number)
          last_option_number = CoAP::Registries::Option::URI_PATH
        end

        encoded.join.b
      end

      def encode_option(option_number, value, last_option_number)
        delta = option_number - last_option_number
        length = value.bytesize

        delta_encoded, delta_extra = encode_extended(delta)
        length_encoded, length_extra = encode_extended(length)

        option_header = [(delta_encoded << 4) | length_encoded].pack('C')
        option_header + delta_extra + length_extra + value.b
      end

      def encode_extended(val)
        case val
        when 0..12
          [val, '']
        when 13..268
          [13, [val - 13].pack('C')]
        when 269..65_804
          [14, [val - 269].pack('n')]
        else
          raise "Unsupported option delta/length: #{val}"
        end
      end
    end
  end
end
