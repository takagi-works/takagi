# frozen_string_literal: true

module Takagi
  module Message
    # Base class for message
    class Base
      attr_reader :version, :type, :token, :message_id, :payload, :options, :code

      def initialize(data = nil, transport: :udp)
        @transport = transport
        if data.is_a?(String) || data.is_a?(IO)
          case transport
          when :tcp
            parse_tcp(data)
          else
            parse(data)
          end
        end
        @data = data
        @logger = Takagi.logger
      end

      # Convert CoAP code number to method name using registry
      # @param code [Integer] CoAP code number
      # @return [String] Method name (e.g., 'GET', 'OBSERVE')
      def coap_code_to_method(code)
        # Check if it's an OBSERVE request (GET with Observe option)
        if code == CoAP::Registries::Method::GET && @options && @options[CoAP::Registries::Option::OBSERVE]
          'OBSERVE'
        else
          # Use CoAP registry to convert code to string
          CoAP::CodeHelpers.to_string(code)
        end
      end

      # Convert method name to CoAP code number using registry
      # @param method [String, Symbol] Method name (e.g., 'GET', :post)
      # @return [Integer] CoAP code number
      def coap_method_to_code(method)
        CoAP::CodeHelpers.to_numeric(method)
      end

      private

      # Parse TCP CoAP message (RFC 8323 §3.2)
      # Format: Len+TKL (1 byte) | Code (1 byte) | Token (TKL bytes) | Options | Payload
      def parse_tcp(data)
        bytes = data.bytes
        first_byte = bytes[0]

        # First byte contains length nibble (upper 4 bits) and TKL (lower 4 bits)
        # But the length nibble is only used for framing, not parsing the message itself
        token_length = first_byte & 0b1111

        @code = bytes[1]
        @token = token_length.positive? ? bytes[2, token_length].pack('C*') : ''.b

        # Parse options starting after code + token
        @options = parse_options(bytes[(2 + token_length)..])
        @payload = extract_payload(data)

        # TCP CoAP doesn't have version, type, or message_id
        @version = nil
        @type = nil
        @message_id = nil
      end

      def parse(data)
        bytes = data.bytes
        @version = (bytes[0] >> 6) & 0b11
        @type    = (bytes[0] >> 4) & 0b11
        token_length = bytes[0] & 0b1111
        @code = bytes[1]
        @message_id = bytes[2..3].pack('C*').unpack1('n')
        @token   = token_length.positive? ? bytes[4, token_length].pack('C*') : ''.b
        @options = parse_options(bytes[(4 + token_length)..])
        @payload = extract_payload(data)
      end

      def parse_options(bytes)
        options = {}
        position = 0
        last_option_number = 0

        while position < bytes.length && bytes[position] != 0xFF
          byte = bytes[position]
          position += 1

          delta_raw = (byte >> 4) & 0x0F
          length_raw = byte & 0x0F

          delta, position = decode_extended_value(bytes, position, delta_raw)
          length, position = decode_extended_value(bytes, position, length_raw)

          option_number = last_option_number + delta
          value = bytes[position, length].pack('C*')
          position += length

          store_option(options, option_number, value)

          last_option_number = option_number
        end

        Takagi.logger.debug "Parsed CoAP options: #{options.inspect}"
        options
      end

      def extract_payload(data)
        Takagi.logger.debug "Extracting payload: #{data.inspect}"
        payload_start = data.index("\xFF".b)
        return nil unless payload_start

        payload = data[(payload_start + 1)..].dup.force_encoding('ASCII-8BIT')
        utf8 = payload.dup.force_encoding('UTF-8')
        utf8.valid_encoding? ? utf8 : payload
      end

      def decode_extended_value(bytes, position, raw_value)
        case raw_value
        when 13
          [bytes[position] + 13, position + 1]
        when 14
          extended = bytes[position, 2].pack('C*').unpack1('n') + 269
          [extended, position + 2]
        else
          [raw_value, position]
        end
      end

      def store_option(options, option_number, value)
        formatted = coerce_option_value(value)

        # Uri-Path (11) and Uri-Query (15) are always stored as arrays
        case option_number
        when CoAP::Registries::Option::URI_PATH, CoAP::Registries::Option::URI_QUERY
          options[option_number] ||= []
          options[option_number] << formatted
        else
          options[option_number] = if options.key?(option_number)
                                     Array(options[option_number]) << formatted
                                   else
                                     formatted
                                   end
        end
      end

      def coerce_option_value(value)
        ascii = value.dup.force_encoding('ASCII-8BIT')
        return ascii.force_encoding('UTF-8') if ascii.valid_encoding?

        ascii
      end
    end
  end
end
