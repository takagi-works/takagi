# frozen_string_literal: true

require_relative 'udp'

module Takagi
  module Network
    module Framing
      # RFC 8323 CoAP over TCP framing with variable-length encoding
      module Tcp
        MAX_MESSAGE_SIZE = 8_388_864
        MAX_TOKEN_LENGTH = 8
        FRAMING_OVERHEAD = 1 + 4 + 1 + MAX_TOKEN_LENGTH
        MAX_FRAME_LENGTH = MAX_MESSAGE_SIZE + FRAMING_OVERHEAD

        def self.bounded_length(length, logger)
          return length if length <= MAX_FRAME_LENGTH

          logger&.debug "read_length: declared length #{length} exceeds the maximum #{MAX_FRAME_LENGTH}; refusing frame"
          nil
        end

        class << self
          # Encode message with RFC 8323 framing
          # @param message [Message::Outbound] Message to encode
          # @return [String] Framed binary data
          # @raise [EmptyMessageError] when an Empty or Reset message carries data
          def encode(message)
            verify_message_shape!(message)
            # Build base message
            packet = build_base_message(message)
            # Add RFC 8323 framing
            frame(packet)
          end

          # Decode framed TCP message
          # @param data [String] Framed binary data
          # @return [Message::Inbound] Parsed message
          def decode(data)
            Message::Inbound.new(data, transport: :tcp)
          end

          # Read a complete message from socket
          # @param socket [TCPSocket] Socket to read from
          # @param logger [Logger] Optional logger for debugging
          # @return [String, nil] Complete framed message or nil
          def read_from_socket(socket, logger: nil)
            first_byte_data = socket.read(1)
            return nil if first_byte_data.nil? || first_byte_data.empty?

            first_byte = first_byte_data.unpack1('C')
            len_nibble = (first_byte >> 4) & 0x0F
            tkl = first_byte & 0x0F

            logger&.debug "read_from_socket: first_byte=0x#{first_byte.to_s(16)}, len_nibble=#{len_nibble}, tkl=#{tkl}"

            length = read_length(socket, len_nibble, logger: logger)
            return nil unless length

            logger&.debug "read_from_socket: message length=#{length} bytes"

            # Read: Code (1) + Token (tkl) + Options + Payload (length)
            bytes_to_read = 1 + tkl + length
            data = +''.b
            remaining = bytes_to_read

            while remaining.positive?
              begin
                chunk = socket.readpartial(remaining)
              rescue IO::WaitReadable
                IO.select([socket])
                retry
              rescue EOFError
                logger&.error "read_from_socket: Incomplete message (expected #{bytes_to_read}, got #{data.bytesize})"
                return nil
              end

              data << chunk
              remaining -= chunk.bytesize
            end

            logger&.debug "read_from_socket: Successfully read #{bytes_to_read} bytes"

            first_byte_data + data
          rescue IOError, Errno::ECONNRESET => e
            logger&.debug "read_from_socket: Socket error (#{e.class}: #{e.message})"
            nil
          end

          private

          def verify_message_shape!(message)
            return unless message.code.zero? || message.type == CoAP::Registries::MessageType::RST
            return if message.code.zero? && message.token.empty? && message.options.empty? && message.payload.to_s.empty?

            raise EmptyMessageError, 'Empty (0.00) and Reset messages carry only the bare header (RFC 7252 4.1/4.2)'
          end

          # Build base TCP message (before framing)
          def build_base_message(message)
            token_length = message.token.bytesize
            # Placeholder length nibble (0)
            first_byte = (0 << 4) | token_length
            packet = [first_byte, message.code].pack('CC')
            packet += message.token.to_s.b
            packet += build_options(message)
            packet += build_payload(message)
            packet.b
          end

          # Add RFC 8323 §3.2 variable-length framing
          def frame(data)
            return ''.b if data.empty?

            first_byte = data.getbyte(0)
            tkl = first_byte & 0x0F

            # RFC 8323 §3.2: Length = size of (Options + Payload)
            # data: first_byte(1) + code(1) + token(tkl) + options + payload
            code_size = 1
            payload_length = [data.bytesize - 1 - code_size - tkl, 0].max

            body = data.byteslice(1, data.bytesize - 1) || ''.b

            if payload_length <= 12
              new_first_byte = (payload_length << 4) | tkl
              [new_first_byte].pack('C') + body
            elsif payload_length <= 268
              new_first_byte = (13 << 4) | tkl
              extension = payload_length - 13
              [new_first_byte, extension].pack('CC') + body
            elsif payload_length <= 65_804
              new_first_byte = (14 << 4) | tkl
              extension = payload_length - 269
              [new_first_byte].pack('C') + [extension].pack('n') + body
            else
              new_first_byte = (15 << 4) | tkl
              extension = payload_length - 65_805
              [new_first_byte].pack('C') + [extension].pack('N') + body
            end
          end

          # Read variable-length field from socket
          def read_length(socket, len_nibble, logger: nil)
            case len_nibble
            when 0..12
              bounded_length(len_nibble, logger)
            when 13
              ext = socket.read(1)
              return nil unless ext

              ext_value = ext.unpack1('C')
              logger&.debug "read_length: extended length byte=0x#{ext_value.to_s(16)}"
              bounded_length(ext_value + 13, logger)
            when 14
              ext = socket.read(2)
              return nil unless ext

              ext_value = ext.unpack1('n')
              logger&.debug "read_length: extended length bytes=0x#{ext_value.to_s(16)}"
              bounded_length(ext_value + 269, logger)
            when 15
              ext = socket.read(4)
              return nil unless ext

              ext_value = ext.unpack1('N')
              logger&.debug "read_length: extended length bytes=0x#{ext_value.to_s(16)}"
              bounded_length(ext_value + 65_805, logger)
            end
          end

          def build_options(message)
            # Reuse UDP framing logic for options (same for TCP and UDP)
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
