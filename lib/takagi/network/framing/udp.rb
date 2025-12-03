# frozen_string_literal: true

module Takagi
  module Network
    module Framing
      # RFC 7252 CoAP over UDP framing
      module Udp
        class << self
          # Encode message to UDP datagram format
          # @param message [Message::Outbound] Message to encode
          # @return [String] Binary UDP datagram
          def encode(message)
            packet = build_header(message)
            packet += message.token.to_s.b
            packet += build_options(message)
            packet += build_payload(message)
            packet.b
          end

          # Decode UDP datagram to message
          # @param data [String] Binary UDP datagram
          # @return [Message::Inbound] Parsed message
          def decode(data)
            Message::Inbound.new(data, transport: :udp)
          end

          private

          def build_header(message)
            version = Takagi::CoAP::VERSION
            type = message.type || CoAP::Registries::MessageType::ACK
            token_length = message.token.bytesize
            version_type_token_length = (version << 6) | (type << 4) | token_length
            [version_type_token_length, message.code, message.message_id].pack('CCn')
          end

          def build_options(message)
            return ''.b if message.options.empty?

            encoded = ''.b
            last_option_number = 0

            flattened_options(message).each do |number, value|
              value_bytes = encode_option_value(value)
              delta = number - last_option_number

              delta_nibble, delta_extension = encode_option_header_value(delta)
              length_nibble, length_extension = encode_option_header_value(value_bytes.bytesize)

              option_byte = (delta_nibble << 4) | length_nibble
              encoded << option_byte.chr
              encoded << delta_extension if delta_extension
              encoded << length_extension if length_extension
              encoded << value_bytes

              last_option_number = number
            end

            encoded
          end

          def build_payload(message)
            return ''.b if message.payload.nil? || message.payload.empty?

            "\xFF".b + message.payload.b
          end

          def flattened_options(message)
            message.options.flat_map do |number, values|
              values.map { |value| [number, value] }
            end.sort_by.with_index { |(number, _), index| [number, index] }
          end

          def encode_option_value(value)
            case value
            when Integer
              encode_integer_option_value(value)
            else
              value.to_s.b
            end
          end

          def encode_integer_option_value(value)
            return ''.b if value.zero?

            bytes = []
            while value.positive?
              bytes << (value & 0xFF)
              value >>= 8
            end
            bytes.reverse.pack('C*')
          end

          def encode_option_header_value(value)
            case value
            when 0..12
              [value, nil]
            when 13..268
              [13, [value - 13].pack('C')]
            when 269..65_804
              [14, [value - 269].pack('n')]
            else
              raise ArgumentError, 'Option value too large'
            end
          end
        end
      end
    end
  end
end
