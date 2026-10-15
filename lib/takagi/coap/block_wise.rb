# frozen_string_literal: true

require_relative 'block_wise/option_value'

module Takagi
  module CoAP
    # RFC 7959 block-wise transfer engine: the Block1/Block2 option-value codec plus
    # slice/join helpers. Self-contained (no coupling outside Takagi::CoAP::Registries)
    # so it stays extractable, mirroring lib/takagi/cbor.
    #
    # @example
    #   blocks = Takagi::CoAP::BlockWise.slice('a' * 4096, szx: 2)
    #   Takagi::CoAP::BlockWise.join(blocks) # => 'a' * 4096
    module BlockWise
      Block = Struct.new(:num, :more, :szx, :payload, keyword_init: true) do
        def size
          OptionValue.size_for(szx)
        end

        def more?
          more ? true : false
        end

        def last?
          !more?
        end

        def option_value
          OptionValue.encode(num: num, more: more?, szx: szx)
        end
      end

      class << self
        def slice(payload, szx: OptionValue::MAX_SZX)
          data = payload.to_s.b
          size = OptionValue.size_for(szx)

          return [Block.new(num: 0, more: false, szx: szx, payload: data)] if data.bytesize <= size

          count = (data.bytesize + size - 1) / size
          Array.new(count) do |index|
            Block.new(
              num: index,
              more: index < count - 1,
              szx: szx,
              payload: data.byteslice(index * size, size)
            )
          end
        end

        def join(blocks)
          list = Array(blocks)
          raise IncompleteError, 'cannot join an empty block sequence' if list.empty?

          expected_szx = list.first.szx
          buffer = String.new(encoding: Encoding::BINARY)
          list.each_with_index do |block, index|
            raise IncompleteError, "expected block number #{index}, got #{block.num}" unless block.num == index

            raise IncompleteError, "block #{index} SZX #{block.szx} does not match #{expected_szx}" unless block.szx == expected_szx

            raise IncompleteError, "block #{index} M flag does not match the sequence" unless block.more? == (index < list.size - 1)

            buffer << block.payload.to_s.b
          end
          buffer
        end
      end
    end
  end
end
