# frozen_string_literal: true

module Takagi
  module CoAP
    module BlockWise
      class Error < StandardError; end

      class EncodeError < Error; end

      class DecodeError < Error; end

      class IncompleteError < Error; end

      # Encodes and decodes the RFC 7959 Block1/Block2 option value (NUM|M|SZX) and maps
      # SZX to block sizes (16..1024 bytes). Pure codec - no wire or transfer state here.
      class OptionValue
        MAX_NUM = (1 << 20) - 1
        MAX_SZX = 6
        RESERVED_SZX = 7
        SZX_MASK = 0b111
        MORE_BIT = 0b1000

        attr_reader :num, :more, :szx

        class << self
          def encode(num: 0, more: false, szx: MAX_SZX)
            new(num: num, more: more, szx: szx).to_s
          rescue Error => e
            raise EncodeError, e.message
          end

          def decode(bytes)
            data = bytes.to_s.b
            return new(num: 0, more: false, szx: 0) if data.empty?

            raise DecodeError, "block option value must be 1..3 bytes, got #{data.bytesize}" unless (1..3).cover?(data.bytesize)

            raw = data.each_byte.reduce(0) { |acc, byte| (acc << 8) | byte }
            new(num: raw >> 4, more: raw.anybits?(MORE_BIT), szx: raw & SZX_MASK)
          rescue Error => e
            raise DecodeError, e.message
          end

          def size_for(szx)
            new(num: 0, more: false, szx: szx).size
          end
        end

        def initialize(num:, more: false, szx: MAX_SZX)
          @num = coerce(num, :num)
          @szx = coerce(szx, :szx)
          @more = more ? true : false
          validate!
          freeze
        end

        def size
          1 << (szx + 4)
        end

        def more?
          more
        end

        def last?
          !more
        end

        def to_s
          raw = (num << 4) | (more ? MORE_BIT : 0) | szx
          bytes = if raw.zero?
                    []
                  elsif raw <= 0xFF
                    [raw]
                  elsif raw <= 0xFFFF
                    [raw >> 8, raw & 0xFF]
                  else
                    [raw >> 16, (raw >> 8) & 0xFF, raw & 0xFF]
                  end
          bytes.pack('C*').freeze
        end

        def ==(other)
          other.is_a?(OptionValue) && other.num == num && other.more? == more? && other.szx == szx
        end
        alias eql? ==

        def hash
          [num, more?, szx].hash
        end

        private

        def coerce(value, name)
          Integer(value)
        rescue TypeError, ArgumentError
          raise Error, "#{name} must be an Integer, got #{value.inspect}"
        end

        def validate!
          raise Error, "num must be 0..#{MAX_NUM}, got #{num}" unless num.between?(0, MAX_NUM)

          raise Error, "SZX #{RESERVED_SZX} is reserved (RFC 7959 2.2)" if szx == RESERVED_SZX

          raise Error, "szx must be 0..#{MAX_SZX}, got #{szx}" unless szx.between?(0, MAX_SZX)
        end
      end
    end
  end
end
