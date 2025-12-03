# frozen_string_literal: true

require 'spec_helper'
require 'stringio'

RSpec.describe Takagi::Server::Tcp do
  subject(:server) do
    instance = described_class.allocate
    instance.instance_variable_set(:@logger, Takagi.logger)
    instance
  end

  describe '#encode_tcp_frame' do
    def decoded_length(frame)
      len = frame.getbyte(0) >> 4

      case len
      when 0..12
        len
      when 13
        13 + frame.getbyte(1)
      when 14
        269 + frame.byteslice(1, 2).unpack1('n')
      else
        65_805 + frame.byteslice(1, 4).unpack1('N')
      end
    end

    it 'encodes short messages with accurate length' do
      message = server.send(:build_csm_message)
      serialized = message.to_bytes(transport: :tcp)
      frame = server.send(:encode_tcp_frame, serialized)

      # Current implementation: Length = Options + Payload
      # serialized format: first_byte(1) + code(1) + token(tkl) + options + payload
      first_byte = serialized.getbyte(0)
      tkl = first_byte & 0x0F
      expected_length = serialized.bytesize - 1 - 1 - tkl # total - first_byte - code - token

      expect(decoded_length(frame)).to eq(expected_length)
      expect(frame.getbyte(0) & 0x0F).to eq(0) # token length unchanged
    end

    it 'encodes extended length messages without truncation' do
      outbound = Takagi::Message::Outbound.new(
        code: Takagi::CoAP::Registries::Response::CONTENT,
        payload: { temperature: 21 },
        token: "\x01\x02",
        options: { Takagi::CoAP::Registries::Option::CONTENT_FORMAT => Takagi::Router::DEFAULT_CONTENT_FORMAT },
        transport: :tcp
      )

      serialized = outbound.to_bytes(transport: :tcp)
      frame = server.send(:encode_tcp_frame, serialized)

      # Current implementation: Length = Options + Payload
      first_byte = serialized.getbyte(0)
      tkl = first_byte & 0x0F
      expected_length = serialized.bytesize - 1 - 1 - tkl # total - first_byte - code - token

      expect(decoded_length(frame)).to eq(expected_length)
      expect(frame.getbyte(0) & 0x0F).to eq(2)
    end
  end

  describe '#read_request' do
    class FakeSocket
      def initialize(payload)
        @io = StringIO.new(payload)
      end

      def read(length)
        @io.read(length)
      end

      def readpartial(length)
        chunk = @io.read(length)
        raise EOFError if chunk.nil?

        chunk
      end

      def nread
        @io.size - @io.pos
      end
    end

    it 'parses framed CSM packets without losing the header byte' do
      message = server.send(:build_csm_message)
      frame = server.send(:encode_tcp_frame, message.to_bytes(transport: :tcp))
      socket = FakeSocket.new(frame)

      inbound = server.send(:read_request, socket)

      expect(inbound.code).to eq(Takagi::CoAP::Registries::Signaling::CSM)
      expect(inbound.token).to eq(''.b)
      expect(inbound.options.keys).to include(2, 4)
    end
  end
end
