# frozen_string_literal: true

require 'securerandom'

module Takagi
  module Message
    # Encodes outbound CoAP request envelopes used by clients and observers.
    #
    # Supports arbitrary CoAP options (Accept, Content-Format, Observe, If-Match,
    # Block1/2, ...). Options whose number is not Uri-Path or Uri-Query are
    # taken from the `options:` keyword; Uri-Path and Uri-Query are derived
    # from the URI automatically. Integer option values are encoded as
    # variable-length big-endian bytes per RFC 7252 §3.2.
    class Request < Base
      attr_reader :message_id, :type, :options

      def initialize(method:, uri:, payload: nil, token: nil, type: nil, options: {}, **kwargs)
        super()
        @method = method
        @uri = uri
        @code = CoAP::CodeHelpers.to_numeric(method)
        @token = token || SecureRandom.hex(4)
        @type = type || CoAP::Registries::MessageType::CON
        @message_id = kwargs[:message_id] || rand(0..0xFFFF)
        @payload = payload
        @options = build_options(options, kwargs)
      end

      # Serializes the request into a CoAP datagram.
      #
      # A Reset is Empty by definition (RFC 7252 4.2), so a request typed as a Reset is
      # emitted as the bare 4-byte header and one that would carry a payload is refused,
      # as is any other Empty (0.00) shape that is not the bare header.
      #
      # @return [String] binary CoAP datagram
      # @raise [Takagi::Network::Framing::EmptyMessageError] when the message must be Empty
      #   (0.00) or is a Reset and it carries a token, options or a payload
      #
      # The empty/reset rule lives in the transport framer ({Takagi::Network::Framing::Udp}),
      # which this encoder consults rather than restating it.
      def to_bytes
        return ''.b unless @code

        return empty_reset_bytes if empty_reset?

        verify_message_shape!

        version = Takagi::CoAP::VERSION
        token_length = @token.bytesize
        ver_type_token = ((version << 6) | (@type << 4) | token_length)
        header = [ver_type_token, CoAP::CodeHelpers.to_numeric(@method), @message_id].pack('CCn')

        packet = (header + @token.b + encode_options + build_payload_section).b
        Takagi.logger.debug "Generated Request packet: #{packet.inspect}"
        packet
      end

      private

      def empty_reset?
        @type == CoAP::Registries::MessageType::RST && @payload.to_s.empty?
      end

      def empty_reset_bytes
        Takagi::Network::Framing::Udp.encode(
          Outbound.new(code: '0.00', type: CoAP::Registries::MessageType::RST, message_id: @message_id, payload: '')
        )
      end

      def verify_message_shape!
        Takagi::Network::Framing::Udp.send(:verify_message_shape!, self)
      end

      def build_options(user_options, kwargs)
        opts = {}

        # User-supplied options (any CoAP option number)
        user_options.each do |k, v|
          num = Integer(k) rescue nil
          next unless num

          opts[num] = normalize_option_value(v)
        end

        # Legacy `observe:` keyword still works
        if kwargs[:observe]
          opts[CoAP::Registries::Option::OBSERVE] = normalize_option_value(kwargs[:observe])
        end

        # Uri-Path segments from URI
        path_segments = @uri.path.to_s.split('/').reject(&:empty?)
        path_segments.each do |segment|
          (opts[CoAP::Registries::Option::URI_PATH] ||= []) << segment
        end

        # Uri-Query from URI
        if @uri.query && !@uri.query.empty?
          @uri.query.split('&').each do |q|
            (opts[CoAP::Registries::Option::URI_QUERY] ||= []) << q
          end
        end

        opts
      end

      def normalize_option_value(value)
        case value
        when Array then value.dup
        when nil then []
        else [value]
        end
      end

      def encode_options
        return ''.b if @options.empty?

        last_option_number = 0
        encoded = +''.b

        # CoAP options must be encoded in ascending order
        sorted_entries = @options.flat_map do |number, values|
          Array(values).map { |v| [number, v] }
        end
        sorted_entries.sort_by.with_index { |(number, _), idx| [number, idx] }.each do |number, value|
          value_bytes = encode_option_value(value)
          length = value_bytes.bytesize
          delta = number - last_option_number

          delta_nibble, delta_ext = encode_extended_nibble(delta)
          length_nibble, length_ext = encode_extended_nibble(length)

          encoded << ((delta_nibble << 4) | length_nibble).chr
          encoded << delta_ext if delta_ext
          encoded << length_ext if length_ext
          encoded << value_bytes

          last_option_number = number
        end

        encoded
      end

      def encode_option_value(value)
        case value
        when Integer
          encode_integer_value(value)
        else
          value.to_s.b
        end
      end

      def encode_integer_value(value)
        return ''.b if value.zero?

        bytes = []
        v = value
        while v.positive?
          bytes << (v & 0xFF)
          v >>= 8
        end
        bytes.reverse.pack('C*')
      end

      def encode_extended_nibble(val)
        case val
        when 0..12
          [val, nil]
        when 13..268
          [13, [val - 13].pack('C')]
        when 269..65_804
          [14, [val - 269].pack('n')]
        else
          raise "Option delta/length too large: #{val}"
        end
      end

      def build_payload_section
        if @payload.nil? || @payload == ''
          ''.b
        elsif @payload.is_a?(String)
          "\xFF".b + @payload.b
        else
          "\xFF".b + @payload.to_json.b
        end
      end
    end
  end
end
