# frozen_string_literal: true

module Takagi
  module Message
    # Raised when a datagram is too short or otherwise malformed to be parsed as a
    # CoAP message (RFC 7252 3: a message format error).
    class ParseError < StandardError; end

    # Base class for message
    class Base
      attr_reader :version, :type, :token, :message_id, :payload, :options, :code, :transport

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
        raise ParseError, "TCP frame is shorter than the 2-byte CoAP-over-TCP header (#{bytes.size} bytes)" if bytes.size < 2

        first_byte = bytes[0]

        # First byte contains length nibble (upper 4 bits) and TKL (lower 4 bits)
        # But the length nibble is only used for framing, not parsing the message itself
        token_length = first_byte & 0b1111

        @code = bytes[1]
        @token = read_token(bytes, 2, token_length)

        if @code.zero?
          @options = {}
          @payload = nil
        else
          # Parse options starting after code + token
          options_start = 2 + token_length
          @options, options_end = parse_options(bytes[options_start..])
          @payload = extract_payload(data, options_start + options_end)
        end

        # TCP CoAP doesn't have version, type, or message_id
        @version = nil
        @type = nil
        @message_id = nil
      end

      def parse(data)
        bytes = data.bytes
        raise ParseError, "datagram is shorter than the 4-byte CoAP header (#{bytes.size} bytes)" if bytes.size < 4

        @version = (bytes[0] >> 6) & 0b11
        @type    = (bytes[0] >> 4) & 0b11
        token_length = bytes[0] & 0b1111
        @code = bytes[1]
        @message_id = bytes[2..3].pack('C*').unpack1('n')
        @token = read_token(bytes, 4, token_length)
        if @code.zero?
          @options = {}
          @payload = nil
        else
          options_start = 4 + token_length
          @options, options_end = parse_options(bytes[options_start..])
          @payload = extract_payload(data, options_start + options_end)
        end
      end

      def read_token(bytes, offset, token_length)
        return ''.b if token_length.zero?

        if bytes.size < offset + token_length
          raise ParseError,
                "token length #{token_length} runs past the end of the message (#{bytes.size} bytes)"
        end

        bytes[offset, token_length].pack('C*')
      end

      # Parses the option sequence of a message.
      #
      # @param bytes [Array<Integer>, nil] message bytes from the first option onwards
      # @return [Array(Hash, Integer)] the options, and the offset within `bytes` where the
      #   sequence ended: the payload marker, or the end of the message when there is none
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
          raise ParseError, "option #{option_number} of #{length} bytes overruns the datagram" if position + length > bytes.length

          value = bytes[position, length].pack('C*')
          position += length

          store_option(options, option_number, value)

          last_option_number = option_number
        end

        Takagi.logger.debug "Parsed CoAP options: #{options.inspect}"
        [options, position]
      end

      # Extracts the payload that follows the marker at `payload_start`.
      #
      # The marker offset comes from {#parse_options}: a 0xFF byte inside the header, the
      # token or an option value is data, not a marker, so searching the message for the
      # first 0xFF would corrupt roughly one message in 256 with random message ids.
      #
      # @param data [String] full message
      # @param payload_start [Integer] offset of the payload marker
      # @return [String, nil] the payload, or nil when the message carries none
      def extract_payload(data, payload_start)
        Takagi.logger.debug "Extracting payload: #{data.inspect}"
        return nil unless data.getbyte(payload_start) == 0xFF

        payload = data[(payload_start + 1)..].dup.force_encoding('ASCII-8BIT')
        utf8 = payload.dup.force_encoding('UTF-8')
        utf8.valid_encoding? ? utf8 : payload
      end

      def decode_extended_value(bytes, position, raw_value)
        case raw_value
        when 13
          raise ParseError, 'option header declares a 1-byte extension past the end of the message' if position >= bytes.length

          [bytes[position] + 13, position + 1]
        when 14
          raise ParseError, 'option header declares a 2-byte extension past the end of the message' if position + 2 > bytes.length

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
