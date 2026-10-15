# frozen_string_literal: true

require 'spec_helper'
require 'takagi/coap/block_wise'
require 'takagi/coap/block_wise/option_value'

RSpec.describe Takagi::CoAP::BlockWise do
  let(:option_value) { Takagi::CoAP::BlockWise::OptionValue }

  describe Takagi::CoAP::BlockWise::OptionValue do
    it 'encodes NUM in the upper bits, M in bit 3 and SZX in the low 3 bits' do
      expect(option_value.encode(num: 0, more: false, szx: 0).bytes).to eq([]) # RFC 7252 section 3.2: uint 0 is a zero-length value
      expect(option_value.encode(num: 0, more: true, szx: 0).bytes).to eq([0x08])
      expect(option_value.encode(num: 5, more: true, szx: 2).bytes).to eq([0x5A])
      expect(option_value.encode(num: 15, more: false, szx: 6).bytes).to eq([0xF6])
      expect(option_value.encode(num: 16, more: false, szx: 0).bytes).to eq([0x01, 0x00])
      expect(option_value.encode(num: 4095, more: true, szx: 6).bytes).to eq([0xFF, 0xFE])
      expect(option_value.encode(num: 4096, more: false, szx: 0).bytes).to eq([0x01, 0x00, 0x00])
      expect(option_value.encode(num: (2**20) - 1, more: true, szx: 6).bytes).to eq([0xFF, 0xFF, 0xFE])
    end

    it 'round-trips NUM 0..2**20-1 for every SZX with both M values' do
      mismatches = []
      wrong_width = []

      (0...(2**20)).each do |num|
        szx = num % 7
        more = num.odd?
        encoded = option_value.encode(num: num, more: more, szx: szx)
        decoded = option_value.decode(encoded)

        unless decoded.num == num && decoded.more? == more && decoded.szx == szx
          mismatches << [num, more, szx, decoded.num, decoded.more?, decoded.szx]
        end

        width = if num.zero?
                  0
                elsif num < 16
                  1
                elsif num < 4096
                  2
                else
                  3
                end
        wrong_width << [num, encoded.bytesize] unless encoded.bytesize == width
      end

      expect(mismatches).to be_empty
      expect(wrong_width).to be_empty
    end

    it 'maps SZX 0..6 to 16..1024 byte block sizes' do
      expect((0..6).map { |szx| option_value.size_for(szx) }).to eq([16, 32, 64, 128, 256, 512, 1024])
      expect((0..6).map { |szx| option_value.decode(option_value.encode(num: 3, more: false, szx: szx)).size })
        .to eq([16, 32, 64, 128, 256, 512, 1024])
    end

    it 'rejects the reserved SZX value 7' do
      expect { option_value.encode(num: 0, more: false, szx: 7) }
        .to raise_error(Takagi::CoAP::BlockWise::EncodeError, /SZX/)
      expect { option_value.decode("\x07") }
        .to raise_error(Takagi::CoAP::BlockWise::DecodeError, /SZX/)
      expect { option_value.decode("\xFF\xFF\xFF") }
        .to raise_error(Takagi::CoAP::BlockWise::DecodeError, /SZX/)
      expect { option_value.size_for(7) }
        .to raise_error(Takagi::CoAP::BlockWise::Error, /SZX/)
    end

    it 'rejects out-of-range NUM and malformed values' do
      expect { option_value.encode(num: -1, more: false, szx: 0) }
        .to raise_error(Takagi::CoAP::BlockWise::EncodeError)
      expect { option_value.encode(num: 2**20, more: false, szx: 0) }
        .to raise_error(Takagi::CoAP::BlockWise::EncodeError)
      expect { option_value.encode(num: nil, more: false, szx: 0) }
        .to raise_error(Takagi::CoAP::BlockWise::EncodeError)
      expect { option_value.encode(num: 0, more: false, szx: 8) }
        .to raise_error(Takagi::CoAP::BlockWise::EncodeError)
      expect(option_value.decode('').then { |value| [value.num, value.more?, value.szx] }).to eq([0, false, 0])
      expect { option_value.decode("\x00\x00\x00\x00") }
        .to raise_error(Takagi::CoAP::BlockWise::DecodeError)
    end

    it 'compares by num, more and szx' do
      expect(option_value.decode(option_value.encode(num: 7, more: true, szx: 3)))
        .to eq(option_value.decode(option_value.encode(num: 7, more: true, szx: 3)))
      expect(option_value.decode(option_value.encode(num: 7, more: true, szx: 3)))
        .not_to eq(option_value.decode(option_value.encode(num: 7, more: false, szx: 3)))
    end
  end

  describe '.slice' do
    it 'splits a payload into ordered blocks with correct M flags' do
      payload = 'abcdefghijklmnopqrstuvwxyz' * 3

      blocks = described_class.slice(payload, szx: 0)

      expect(blocks.map(&:num)).to eq([0, 1, 2, 3, 4])
      expect(blocks.map(&:more?)).to eq([true, true, true, true, false])
      expect(blocks.map(&:szx).uniq).to eq([0])
      expect(blocks.map { |block| block.payload.bytesize }).to eq([16, 16, 16, 16, 14])
      expect(blocks.map(&:payload).join).to eq(payload)
      expect(blocks.last.last?).to be(true)
    end

    it 'describes each block with its own option value' do
      blocks = described_class.slice('abcdefghijklmnopqrstuvwxyz' * 3, szx: 0)

      expect(blocks[1].option_value).to eq(option_value.encode(num: 1, more: true, szx: 0))
      decoded = option_value.decode(blocks[1].option_value)
      expect([decoded.num, decoded.more?, decoded.szx]).to eq([1, true, 0])
      expect(decoded.size).to eq(16)
      expect(blocks.last.option_value).to eq(option_value.encode(num: 4, more: false, szx: 0))
    end

    it 'does not emit a trailing empty block for an exact multiple' do
      blocks = described_class.slice('x' * 32, szx: 0)

      expect(blocks.size).to eq(2)
      expect(blocks.map(&:num)).to eq([0, 1])
      expect(blocks.map(&:more?)).to eq([true, false])
      expect(blocks.last.payload).to eq('x' * 16)
    end

    it 'emits a single final block for an empty payload' do
      blocks = described_class.slice('', szx: 6)

      expect(blocks.size).to eq(1)
      expect(blocks.first.num).to eq(0)
      expect(blocks.first.more?).to be(false)
      expect(blocks.first.payload).to eq('')
    end

    it 'defaults to 1024 byte blocks and slices binary payloads' do
      payload = Random.new(1234).bytes(4096)

      blocks = described_class.slice(payload)

      expect(blocks.size).to eq(4)
      expect(blocks.map(&:szx).uniq).to eq([6])
      expect(blocks.map(&:more?)).to eq([true, true, true, false])
      expect(blocks.map { |block| block.payload.bytesize }).to eq([1024, 1024, 1024, 1024])
      expect(described_class.join(blocks)).to eq(payload)
    end
  end

  describe '.join' do
    it 'reassembles a sliced payload exactly at every block size' do
      payload = Random.new(99).bytes(3000)

      (0..6).each do |szx|
        blocks = described_class.slice(payload, szx: szx)

        expect(blocks.first.szx).to eq(szx)
        expect(described_class.join(blocks)).to eq(payload)
      end
    end

    it 'leaves a payload smaller than one block intact' do
      payload = Random.new(7).bytes(10)

      blocks = described_class.slice(payload, szx: 0)

      expect(blocks.size).to eq(1)
      expect(described_class.join(blocks)).to eq(payload)
    end

    it 'raises on a gap in the sequence' do
      blocks = described_class.slice('abcdefghij' * 8, szx: 1)
      with_gap = blocks.reject.with_index { |_block, index| index == 1 }

      expect { described_class.join(with_gap) }
        .to raise_error(Takagi::CoAP::BlockWise::IncompleteError, /block number 1/)
    end

    it 'raises on out-of-order blocks' do
      blocks = described_class.slice('abcdefghij' * 8, szx: 1)

      expect { described_class.join(blocks.reverse) }
        .to raise_error(Takagi::CoAP::BlockWise::IncompleteError, /block number 0/)
    end

    it 'raises when the final block is missing' do
      blocks = described_class.slice('abcdefghij' * 8, szx: 1)

      expect { described_class.join(blocks[0..-2]) }
        .to raise_error(Takagi::CoAP::BlockWise::IncompleteError, /M flag/)
    end

    it 'raises on an empty sequence' do
      expect { described_class.join([]) }
        .to raise_error(Takagi::CoAP::BlockWise::IncompleteError)
    end

    it 'raises when block sizes disagree' do
      first = described_class.slice('x' * 32, szx: 0).first
      second = described_class::Block.new(num: 1, more: false, szx: 1, payload: 'y' * 16)

      expect { described_class.join([first, second]) }
        .to raise_error(Takagi::CoAP::BlockWise::IncompleteError, /SZX/)
    end
  end
end
