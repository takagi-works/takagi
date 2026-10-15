# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Takagi::CBOR::Encoder do
  describe '.encode' do
    it 'encodes small unsigned integers (0-23) in one byte' do
      expect(described_class.encode(0)).to eq("\x00".b)
      expect(described_class.encode(10)).to eq("\x0A".b)
      expect(described_class.encode(23)).to eq("\x17".b)
    end

    it 'encodes uint8 (24-255)' do
      expect(described_class.encode(24)).to eq("\x18\x18".b)
      expect(described_class.encode(100)).to eq("\x18d".b)
      expect(described_class.encode(255)).to eq("\x18\xFF".b)
    end

    it 'encodes uint16 (256-65535)' do
      expect(described_class.encode(256)).to eq("\x19\x01\x00".b)
      expect(described_class.encode(1000)).to eq("\x19\x03\xE8".b)
      expect(described_class.encode(65535)).to eq("\x19\xFF\xFF".b)
    end

    it 'encodes uint32' do
      expect(described_class.encode(65536)).to eq("\x1A\x00\x01\x00\x00".b)
      expect(described_class.encode(1_000_000)).to eq("\x1A\x00\x0F\x42\x40".b)
    end

    it 'encodes uint64' do
      expect(described_class.encode(4_294_967_296)).to eq("\x1B\x00\x00\x00\x01\x00\x00\x00\x00".b)
    end

    it 'encodes negative integers' do
      expect(described_class.encode(-1)).to eq("\x20".b)
      expect(described_class.encode(-10)).to eq("\x29".b)
      expect(described_class.encode(-100)).to eq("\x38\x63".b)
      expect(described_class.encode(-1000)).to eq("\x39\x03\xE7".b)
    end

    it 'encodes UTF-8 strings' do
      expect(described_class.encode('')).to eq("\x60".b)
      expect(described_class.encode('a')).to eq("\x61a".b)
      expect(described_class.encode('IETF')).to eq("\x64IETF".b)
      expect(described_class.encode('hello world')).to eq("\x6Bhello world".b)
    end

    it 'encodes symbols as strings' do
      expect(described_class.encode(:hello)).to eq("\x65hello".b)
    end

    it 'handles UTF-8 multibyte characters' do
      # "ä" is 2 bytes in UTF-8
      result = described_class.encode('ä')
      expect(result[0].ord).to eq(0x62) # Text string, length 2
      expect(result[1..2]).to eq('ä')
    end

    it 'encodes arrays' do
      expect(described_class.encode([])).to eq("\x80".b)
      expect(described_class.encode([1, 2, 3])).to eq("\x83\x01\x02\x03".b)
      expect(described_class.encode([1, [2, 3], [4, 5]])).to eq("\x83\x01\x82\x02\x03\x82\x04\x05".b)
    end

    it 'encodes hashes (maps)' do
      expect(described_class.encode({})).to eq("\xA0".b)
      # Note: Hash order may vary, so we check structure
      result = described_class.encode({ 'a' => 1 })
      expect(result[0].ord).to eq(0xA1) # Map with 1 pair
    end

    it 'encodes booleans' do
      expect(described_class.encode(false)).to eq("\xF4".b)
      expect(described_class.encode(true)).to eq("\xF5".b)
    end

    it 'encodes nil' do
      expect(described_class.encode(nil)).to eq("\xF6".b)
    end

    it 'encodes a binary string as a byte string' do
      result = described_class.encode("\x01\x02\xFF".b)
      expect(result).to eq("\x43\x01\x02\xFF".b)
    end

    it 'still encodes UTF-8 strings as text strings' do
      expect(described_class.encode('hi')).to eq("\x62hi".b)
    end

    it 'round-trips a byte string through the decoder' do
      bytes = "\x00\xFF\x10".b
      expect(Takagi::CBOR::Decoder.decode(described_class.encode(bytes))).to eq(bytes)
    end

    it 'encodes floats as 64-bit IEEE 754' do
      result = described_class.encode(1.5)
      expect(result[0].ord).to eq(0xFB) # Major type 7, float64
      expect(result.bytesize).to eq(9) # 1 byte header + 8 bytes data
    end

    it 'encodes Time as epoch timestamp (tag 1)' do
      time = Time.at(1_363_896_240) # March 21, 2013
      result = described_class.encode(time)
      # Tag 1 (epoch timestamp) + integer encoding
      expect(result[0].ord).to eq(0xC1) # Major type 6, tag 1
      expect(result[1].ord).to eq(0x1A) # uint32 follows
    end

    it 'encodes complex nested structures' do
      data = {
        'name' => 'sensor',
        'value' => 25.5,
        'tags' => ['temperature', 'room1'],
        'active' => true
      }
      result = described_class.encode(data)
      expect(result).to be_a(String)
      expect(result.encoding).to eq(Encoding::BINARY)
    end

    it 'raises EncodeError for unsupported types' do
      expect { described_class.encode(Object.new) }.to raise_error(Takagi::CBOR::EncodeError)
    end

    it 'raises EncodeError for integers that are too large' do
      max_uint64 = (2**64) - 1
      expect { described_class.encode(max_uint64 + 1) }.to raise_error(Takagi::CBOR::EncodeError, /too large/)
    end

    it 'handles roundtrip encoding/decoding' do
      original = { 'temperature' => 25.5, 'humidity' => 60, 'sensors' => ['temp1', 'hum1'] }
      encoded = described_class.encode(original)
      decoded = Takagi::CBOR::Decoder.decode(encoded)
      expect(decoded).to eq(original)
    end

    it 'produces deterministic output for same input' do
      data = [1, 2, 3]
      result1 = described_class.encode(data)
      result2 = described_class.encode(data)
      expect(result1).to eq(result2)
    end

    it 'uses minimal encoding for integers' do
      # 23 should use 1 byte, not 2
      expect(described_class.encode(23).bytesize).to eq(1)
      # 24 requires 2 bytes
      expect(described_class.encode(24).bytesize).to eq(2)
      # 256 requires 3 bytes
      expect(described_class.encode(256).bytesize).to eq(3)
    end
  end
end
