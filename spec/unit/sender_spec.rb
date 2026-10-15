# frozen_string_literal: true

require 'digest'

RSpec.describe Takagi::Observer::Sender do
  it 'sends CoAP packet to subscriber' do
    port = find_free_port
    fake_server = UDPSocket.new
    fake_server.bind('127.0.0.1', port)

    socket = UDPSocket.new
    Takagi::Network::UdpSender.instance.setup(socket: socket)

    subscriber = { address: '127.0.0.1', port: port, token: 'abc' }

    sender = described_class.new
    sender.send_packet(subscriber, 'Hello')

    data, _addr = fake_server.recvfrom(1024)
    expect(data).to include('Hello')

    fake_server.close
    socket.close
  end

  describe 'block-wise notifications' do
    let(:option_value) { Takagi::CoAP::BlockWise::OptionValue }

    before do
      @subscriber = UDPSocket.new
      @subscriber.bind('127.0.0.1', 0)
      @previous_socket = Takagi::Network::UdpSender.instance.instance_variable_get(:@socket)
      Takagi::Network::UdpSender.instance.setup(socket: UDPSocket.new)
    end

    after do
      Takagi::Network::UdpSender.instance.setup(socket: @previous_socket)
      @subscriber.close
    end

    # Sends one notification and returns the raw datagram the subscriber received.
    def deliver(value)
      sender = described_class.new
      sender.send_packet({ address: '127.0.0.1', port: @subscriber.addr[1], token: 'abc' }, value)
      raise 'no notification within 5s' unless @subscriber.wait_readable(5)

      @subscriber.recvfrom(65_535).first
    end

    def option(message, number)
      Array(message.option(number)).first
    end

    def uint_value(bytes)
      bytes.to_s.b.bytes.reduce(0) { |acc, byte| (acc << 8) | byte }
    end

    it 'sends a value that fits one datagram unchanged, with no Block2 option' do
      notification = Takagi::Message::Inbound.new(deliver('Hello'))

      expect(notification.payload).to eq('Hello')
      expect(notification.token).to eq('abc')
      expect(option(notification, Takagi::CoAP::Registries::Option::BLOCK2)).to be_nil
      expect(option(notification, Takagi::CoAP::Registries::Option::SIZE2)).to be_nil
    end

    it 'sends the first Block2 block of a value that exceeds one datagram' do
      value = 'x' * 3072
      data = deliver(value)
      notification = Takagi::Message::Inbound.new(data)
      block = option_value.decode(option(notification, Takagi::CoAP::Registries::Option::BLOCK2))

      expect(block.num).to eq(0)
      expect(block.more?).to be(true)
      expect(block.szx).to eq(6)
      expect(notification.payload).to eq(value.byteslice(0, 1024))
      expect(data.bytesize).to be < 1200
      expect(uint_value(option(notification, Takagi::CoAP::Registries::Option::SIZE2))).to eq(value.bytesize)
      expect(option(notification, Takagi::CoAP::Registries::Option::ETAG).to_s.b).to eq(Digest::SHA256.digest(value).byteslice(0, 8))
    end

    it 'leaves a value of exactly one block in one datagram' do
      notification = Takagi::Message::Inbound.new(deliver('y' * 1024))

      expect(notification.payload.bytesize).to eq(1024)
      expect(option(notification, Takagi::CoAP::Registries::Option::BLOCK2)).to be_nil
    end

    it 'sends the whole value when block-wise transfer is disabled' do
      previous = Takagi.config.block_wise.enabled
      Takagi.config.block_wise.enabled = false
      notification = Takagi::Message::Inbound.new(deliver('z' * 3072))

      expect(notification.payload.bytesize).to eq(3072)
      expect(option(notification, Takagi::CoAP::Registries::Option::BLOCK2)).to be_nil
    ensure
      Takagi.config.block_wise.enabled = previous
    end
  end
end
