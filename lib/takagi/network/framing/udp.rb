# frozen_string_literal: true

module Takagi
  module Network
    module Framing
      # Raised when a caller asks a framer to serialize data that an Empty
      # (code 0.00) or Reset message cannot carry: RFC 7252 4.1 defines an Empty
      # message as the bare 4-byte header, and 4.2 requires a Reset to be Empty.
      #
      # Inherits from ScriptError, not StandardError, because
      # Message::Outbound#to_bytes rescues StandardError and would otherwise
      # swallow the programming error and emit an empty packet.
      class EmptyMessageError < ScriptError
      end

      # RFC 7252 CoAP over UDP framing
      module Udp
        class << self
          # Encode message to UDP datagram format
          # @param message [Message::Outbound] Message to encode
          # @return [String] Binary UDP datagram
          # @raise [EmptyMessageError] when an Empty or Reset message carries data
          def encode(message)
            verify_message_shape!(message)
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

          def verify_message_shape!(message)
            return unless message.code.zero? || message.type == CoAP::Registries::MessageType::RST
            return if message.code.zero? && message.token.empty? && message.options.empty? && message.payload.to_s.empty?

            raise EmptyMessageError, 'Empty (0.00) and Reset messages carry only the bare header (RFC 7252 4.1/4.2)'
          end

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
