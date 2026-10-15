# frozen_string_literal: true

require 'spec_helper'
require 'takagi/coap/block_wise'
require 'takagi/coap/block_wise/option_value'

# Byte vectors from RFC 7959 §2.2 (Figure 1: NUM|M|SZX) and the worked option values
# 33 / 59 cited in RFC 7959 §3. Each entry is hex => [NUM, M, SZX, block size].
RFC_VECTORS = {
  '0x08' => [0, true, 0, 16],
  '0x0A' => [0, true, 2, 64],
  '0x0F' => [0, true, 7, nil],
  '0x10' => [1, false, 0, 16],
  '0x21' => [2, false, 1, 32],
  '0x3B' => [3, true, 3, 128],
  '0xF6' => [15, false, 6, 1024]
}.freeze

RSpec.describe 'RFC 7959 block option vectors' do
  let(:option_value) { Takagi::CoAP::BlockWise::OptionValue }

  describe 'encode (fields -> wire bytes)' do
    RFC_VECTORS.each do |hex, (num, more, szx, _size)|
      next if szx == 7

      it "encodes NUM=#{num} M=#{more ? 1 : 0} SZX=#{szx} as #{hex}" do
        expect(option_value.encode(num: num, more: more, szx: szx).bytes)
          .to eq(hex.delete_prefix('0x').scan(/../).map { |pair| pair.to_i(16) })
      end
    end

    it 'encodes the 2-byte and 3-byte widths at the uint boundaries' do
      expect(option_value.encode(num: 16, more: false, szx: 0).bytes).to eq([0x01, 0x00])
      expect(option_value.encode(num: 255, more: false, szx: 6).bytes).to eq([0x0F, 0xF6])
      expect(option_value.encode(num: 4096, more: false, szx: 0).bytes).to eq([0x01, 0x00, 0x00])
      expect(option_value.encode(num: (2**20) - 1, more: true, szx: 6).bytes)
        .to eq([0xFF, 0xFF, 0xFE])
    end
  end

  describe 'decode (wire bytes -> fields)' do
    RFC_VECTORS.each do |hex, (num, more, szx, size)|
      next if szx == 7

      it "decodes #{hex} into NUM=#{num} M=#{more ? 1 : 0} SZX=#{szx} (#{size} bytes)" do
        bytes = hex.delete_prefix('0x').scan(/../).map { |pair| pair.to_i(16) }.pack('C*')
        decoded = option_value.decode(bytes)

        expect([decoded.num, decoded.more?, decoded.szx]).to eq([num, more, szx])
        expect(decoded.size).to eq(size)
      end
    end

    it 'round-trips the RFC §3 example values 33 and 59 byte-for-byte' do
      expect(option_value.decode("\x21".b).then { |v| [v.num, v.more?, v.szx, v.size] })
        .to eq([2, false, 1, 32])
      expect(option_value.decode("\x3b".b).then { |v| [v.num, v.more?, v.szx, v.size] })
        .to eq([3, true, 3, 128])
      expect(option_value.decode(option_value.encode(num: 2, more: false, szx: 1))).to eq(
        option_value.decode("\x21".b)
      )
      expect(option_value.decode(option_value.encode(num: 3, more: true, szx: 3))).to eq(
        option_value.decode("\x3b".b)
      )
    end
  end

  describe 'SZX -> block size (2**(SZX + 4))' do
    it 'maps SZX 0..6 to 16, 32, 64, 128, 256, 512, 1024 bytes' do
      expect((0..6).map { |szx| option_value.size_for(szx) }).to eq([16, 32, 64, 128, 256, 512, 1024])
    end

    it 'reports the same size through a decoded option for every SZX' do
      (0..6).each do |szx|
        decoded = option_value.decode(option_value.encode(num: 0, more: true, szx: szx))
        expect(decoded.size).to eq(2**(szx + 4))
      end
    end
  end

  describe 'reserved SZX 7 (RFC 7959 §2.2: "MUST NOT be sent")' do
    it 'never encodes 0x0F and rejects SZX 7 on decode' do
      expect { option_value.encode(num: 0, more: true, szx: 7) }
        .to raise_error(Takagi::CoAP::BlockWise::EncodeError)
      expect { option_value.decode("\x0f".b) }
        .to raise_error(Takagi::CoAP::BlockWise::DecodeError, /SZX/)
    end
  end

  # RFC 7959 section 2.2 delegates the option encoding to RFC 7252 section 3.2, where a
  # uint of value 0 occupies zero bytes. So NUM=0/M=0/SZX=0 is the empty option value.
  describe 'zero-value encoding (RFC 7252 section 3.2 uint)' do
    it 'encodes NUM=0 M=0 SZX=0 as a zero-length option value' do
      expect(option_value.encode(num: 0, more: false, szx: 0)).to eq(''.b)
      expect(option_value.encode(num: 0, more: false, szx: 0).bytes).to eq([])

      decoded = option_value.decode(''.b)
      expect([decoded.num, decoded.more?, decoded.szx, decoded.size]).to eq([0, false, 0, 16])
    end
  end
end
