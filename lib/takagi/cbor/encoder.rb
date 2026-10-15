# frozen_string_literal: true

module Takagi
  module CBOR
    # CBOR Encoder (RFC 8949)
    #
    # Encodes Ruby objects to CBOR binary format.
    # Optimized for IoT/CoAP workloads with minimal footprint.
    #
    # Supported types:
    # - Integers (signed/unsigned, up to 64-bit)
    # - Floats (64-bit IEEE 754)
    # - Strings (UTF-8)
    # - Byte strings (binary data)
    # - Arrays
    # - Hashes (maps)
    # - Booleans (true/false)
    # - nil (null)
    # - Time (timestamp, tag 1)
    #
    # @example Basic encoding
    #   Encoder.encode({ temperature: 25.5, humidity: 60 })
    #   # => "\xA2ktempera..." (CBOR bytes)
    #
    # @example Encoding with symbols
    #   Encoder.encode({ temp: 25.5 })
    #   # Symbols converted to strings
    class Encoder
      # CBOR Major Types (RFC 8949 §3)
      MAJOR_TYPE_UNSIGNED_INT = 0
      MAJOR_TYPE_NEGATIVE_INT = 1
      MAJOR_TYPE_BYTE_STRING = 2
      MAJOR_TYPE_TEXT_STRING = 3
      MAJOR_TYPE_ARRAY = 4
      MAJOR_TYPE_MAP = 5
      MAJOR_TYPE_TAG = 6
      MAJOR_TYPE_SIMPLE = 7

      # Simple values (RFC 8949 §3.3)
      SIMPLE_FALSE = 20
      SIMPLE_TRUE = 21
      SIMPLE_NULL = 22
      SIMPLE_FLOAT64 = 27

      # Tag values (RFC 8949 §3.4)
      TAG_EPOCH_TIMESTAMP = 1

      # Maximum safe integer values
      MAX_UINT8 = 0xFF
      MAX_UINT16 = 0xFFFF
      MAX_UINT32 = 0xFFFFFFFF
      MAX_UINT64 = 0xFFFFFFFFFFFFFFFF

      TYPE_HANDLERS = {
        Integer => :encode_integer,
        Float => :encode_float,
        Array => :encode_array,
        Hash => :encode_map,
        TrueClass => :encode_simple,
        FalseClass => :encode_simple,
        NilClass => :encode_simple,
        Time => :encode_timestamp
      }.freeze

      class << self
        # Encode a Ruby object to CBOR bytes
        #
        # @param obj [Object] Ruby object to encode
        # @return [String] CBOR-encoded binary string
        # @raise [EncodeError] if object cannot be encoded
        #
        # @example
        #   Encoder.encode(42)              # => "\x18\x2A"
        #   Encoder.encode("hello")         # => "ehello"
        #   Encoder.encode([1, 2, 3])       # => "\x83\x01\x02\x03"
        #   Encoder.encode({ a: 1 })        # => "\xA1aa\x01"
        def encode(obj)
          new.encode(obj)
        end
      end

      # Encode a Ruby object to CBOR bytes
      #
      # @param obj [Object] Ruby object to encode
      # @return [String] CBOR-encoded binary string
      # @raise [EncodeError] if object cannot be encoded
      def encode(obj)
        encode_value(obj)
      end

      private

      def encode_value(obj)
        handler = handler_for(obj)
        send(handler, obj)
      rescue EncodeError
        raise
      rescue StandardError => e
        raise EncodeError, "Encoding failed: #{e.message}"
      end

      def handler_for(obj)
        return :encode_symbol if obj.is_a?(Symbol)
        return :encode_byte_string if binary_string?(obj)
        return :encode_string if obj.is_a?(String)

        TYPE_HANDLERS.each do |klass, method|
          return method if obj.is_a?(klass)
        end

        raise EncodeError, "Cannot encode #{obj.class}: #{obj.inspect}"
      end

      def binary_string?(obj)
        obj.is_a?(String) && (obj.encoding == Encoding::BINARY || !obj.valid_encoding?)
      end

      def encode_symbol(symbol)
        encode_string(symbol.to_s)
      end

      # Encode integer (major type 0 or 1)
      def encode_integer(int)
        if int >= 0
          encode_unsigned_int(int)
        else
          encode_negative_int(int)
        end
      end

      # Encode unsigned integer (major type 0)
      # RFC 8949 §3.1
      def encode_unsigned_int(int)
        raise EncodeError, "Integer too large: #{int}" if int > MAX_UINT64

        encode_with_length(MAJOR_TYPE_UNSIGNED_INT, int)
      end

      # Encode negative integer (major type 1)
      # RFC 8949 §3.1: -1 - n
      def encode_negative_int(int)
        # Convert to CBOR representation: -1 - n
        # Example: -1 => 0, -2 => 1, -500 => 499
        n = -1 - int

        raise EncodeError, "Integer too small: #{int}" if n > MAX_UINT64

        encode_with_length(MAJOR_TYPE_NEGATIVE_INT, n)
      end

      # Encode float (major type 7, additional info 27)
      # RFC 8949 §3.3: Always use 64-bit IEEE 754
      def encode_float(float)
        # Major type 7, additional info 27 (64-bit float)
        major_byte = (MAJOR_TYPE_SIMPLE << 5) | SIMPLE_FLOAT64

        # Pack as big-endian 64-bit float (network byte order)
        [major_byte].pack('C') + [float].pack('G')
      end

      # Encode UTF-8 string (major type 3)
      # RFC 8949 §3.1
      def encode_string(str)
        # Ensure UTF-8 encoding
        utf8_str = str.encode('UTF-8')
        byte_length = utf8_str.bytesize

        encode_with_length(MAJOR_TYPE_TEXT_STRING, byte_length) + utf8_str
      end

      def encode_byte_string(bytes)
        binary = bytes.b
        encode_with_length(MAJOR_TYPE_BYTE_STRING, binary.bytesize) + binary
      end

      # Encode array (major type 4)
      # RFC 8949 §3.1
      def encode_array(arr)
        result = encode_with_length(MAJOR_TYPE_ARRAY, arr.size)

        arr.each do |item|
          result << encode_value(item)
        end

        result
      end

      # Encode map/hash (major type 5)
      # RFC 8949 §3.1
      def encode_map(hash)
        result = encode_with_length(MAJOR_TYPE_MAP, hash.size)

        hash.each do |key, value|
          result << encode_value(key)
          result << encode_value(value)
        end

        result
      end

      # Encode simple values (major type 7)
      # RFC 8949 §3.3
      def encode_simple(obj)
        simple_value = case obj
                       when false then SIMPLE_FALSE
                       when true then SIMPLE_TRUE
                       when nil then SIMPLE_NULL
                       end

        major_byte = (MAJOR_TYPE_SIMPLE << 5) | simple_value
        [major_byte].pack('C')
      end

      # Encode timestamp (tag 1, epoch seconds)
      # RFC 8949 §3.4.2
      def encode_timestamp(time)
        # Tag 1: Epoch-based timestamp (integer seconds since 1970-01-01)
        tag_byte = encode_with_length(MAJOR_TYPE_TAG, TAG_EPOCH_TIMESTAMP)

        # Encode timestamp as integer (seconds since epoch)
        timestamp_int = time.to_i

        tag_byte + encode_value(timestamp_int)
      end

      # Encode major type with length/value
      # RFC 8949 §3: Additional Information encoding
      #
      # Additional info:
      # 0-23:   Value directly in additional info
      # 24:     1-byte uint8 follows
      # 25:     2-byte uint16 follows
      # 26:     4-byte uint32 follows
      # 27:     8-byte uint64 follows
      def encode_with_length(major_type, length)
        if length < 24
          # Value fits in additional info (0-23)
          major_byte = (major_type << 5) | length
          [major_byte].pack('C')
        elsif length <= MAX_UINT8
          # 1-byte length follows (24-255)
          major_byte = (major_type << 5) | 24
          [major_byte, length].pack('CC')
        elsif length <= MAX_UINT16
          # 2-byte length follows (256-65535)
          major_byte = (major_type << 5) | 25
          [major_byte].pack('C') + [length].pack('n')
        elsif length <= MAX_UINT32
          # 4-byte length follows
          major_byte = (major_type << 5) | 26
          [major_byte].pack('C') + [length].pack('N')
        elsif length <= MAX_UINT64
          # 8-byte length follows
          major_byte = (major_type << 5) | 27
          [major_byte].pack('C') + [length].pack('Q>')
        else
          raise EncodeError, "Length too large: #{length}"
        end
      end
    end
  end
end
