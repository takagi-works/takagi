# frozen_string_literal: true

require 'spec_helper'
require 'stringio'

RSpec.describe Takagi::Server::Tcp do
  subject(:server) do
    instance = described_class.allocate
    instance.instance_variable_set(:@logger, Takagi.logger)
    instance
  end

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

  describe 'TCP framing (live path)' do
    it 'round-trips a CSM message through the live framer and reader' do
      message = server.send(:build_csm_message)
      frame = Takagi::Network::Framing::Tcp.encode(message)

      inbound = server.send(:read_request, FakeSocket.new(frame))

      expect(inbound.code).to eq(Takagi::CoAP::Registries::Signaling::CSM)
      expect(inbound.token).to eq(''.b)
      expect(inbound.options.keys).to include(2)
      expect(inbound.options.keys).not_to include(4)
    end

    it 'round-trips an extended-length payload' do
      outbound = Takagi::Message::Outbound.new(
        code: Takagi::CoAP::Registries::Response::CONTENT,
        payload: { temperature: 21, note: 'x' * 300 },
        token: "\x01\x02".b,
        options: { Takagi::CoAP::Registries::Option::CONTENT_FORMAT => Takagi::Router::DEFAULT_CONTENT_FORMAT },
        transport: :tcp
      )
      frame = Takagi::Network::Framing::Tcp.encode(outbound)

      inbound = server.send(:read_request, FakeSocket.new(frame))

      expect(inbound.code).to eq(Takagi::CoAP::Registries::Response::CONTENT)
      expect(inbound.token).to eq("\x01\x02".b)
      expect(inbound.payload).to include('temperature')
    end
  end

  describe Takagi::Network::Framing::Tcp do
    def frame_with_declared_length(declared, body: nil)
      header = [15 << 4].pack('C') + [declared - 65_805].pack('N')
      header + "\x45".b + (body || ("\xFF".b + ('a' * (declared - 1))))
    end

    it 'derives the maximum from the Max-Message-Size the server advertises' do
      tcp_server = Takagi::Server::Tcp.allocate
      tcp_server.instance_variable_set(:@logger, Takagi.logger)
      advertised = tcp_server.send(:build_csm_message).options[2].first

      expect(described_class::MAX_MESSAGE_SIZE).to eq(advertised)
    end

    it 'refuses a frame declaring a length above the maximum without reading the body' do
      declared = described_class::MAX_FRAME_LENGTH + 1
      socket = FakeSocket.new(frame_with_declared_length(declared, body: ''.b))
      requested = []
      allow(socket).to receive(:readpartial).and_wrap_original do |original, length|
        requested << length
        original.call(length)
      end

      expect(described_class.read_from_socket(socket)).to be_nil
      expect(requested).to be_empty
    end

    it 'reads a frame declaring a length just below the maximum' do
      declared = described_class::MAX_FRAME_LENGTH - 1
      frame = frame_with_declared_length(declared)

      result = described_class.read_from_socket(FakeSocket.new(frame))

      expect(result).to eq(frame.byteslice(0, 1) + frame.byteslice(5, frame.bytesize - 5))
    end
  end
end
