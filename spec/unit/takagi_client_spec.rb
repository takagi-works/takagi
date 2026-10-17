# frozen_string_literal: true

require 'digest'
require 'json'
require 'uri'

RSpec.describe Takagi::UdpClient do
  let(:server_uri) { 'coap://127.0.0.1:5683' }

  describe '#initialize' do
    it 'creates a client with retransmission enabled by default' do
      client = described_class.new(server_uri)
      expect(client.instance_variable_get(:@use_retransmission)).to be true
      expect(client.instance_variable_get(:@retransmission_manager)).to be_a(Takagi::Message::RetransmissionManager)
      client.close
    end

    it 'allows disabling retransmission' do
      client = described_class.new(server_uri, use_retransmission: false)
      expect(client.instance_variable_get(:@use_retransmission)).to be false
      expect(client.instance_variable_get(:@retransmission_manager)).to be_nil
      client.close
    end

    it 'starts the retransmission manager thread' do
      client = described_class.new(server_uri)
      manager = client.instance_variable_get(:@retransmission_manager)
      expect(manager.instance_variable_get(:@running)).to be true
      expect(manager.instance_variable_get(:@thread)).to be_alive
      client.close
    end
  end

  describe '#close' do
    it 'stops the retransmission manager' do
      client = described_class.new(server_uri)
      manager = client.instance_variable_get(:@retransmission_manager)

      client.close

      # Give the thread a moment to stop
      sleep 0.2

      expect(manager.instance_variable_get(:@running)).to be false
      expect(client.closed?).to be true
    end

    it 'is idempotent' do
      client = described_class.new(server_uri)

      expect { client.close }.not_to raise_error
      expect { client.close }.not_to raise_error

      expect(client.closed?).to be true
    end

    it 'works when retransmission is disabled' do
      client = described_class.new(server_uri, use_retransmission: false)

      expect { client.close }.not_to raise_error
      expect(client.closed?).to be true
    end
  end

  describe '.open' do
    it 'automatically closes the client after the block' do
      manager = nil

      described_class.open(server_uri) do |client|
        manager = client.instance_variable_get(:@retransmission_manager)
        expect(client.closed?).to be false
      end

      # Give the thread a moment to stop
      sleep 0.2

      expect(manager.instance_variable_get(:@running)).to be false
    end

    it 'closes the client even if an error occurs' do
      manager = nil

      expect do
        described_class.open(server_uri) do |client|
          manager = client.instance_variable_get(:@retransmission_manager)
          raise 'Test error'
        end
      end.to raise_error('Test error')

      # Give the thread a moment to stop
      sleep 0.2

      expect(manager.instance_variable_get(:@running)).to be false
    end

    it 'returns the block value' do
      result = described_class.open(server_uri) do |_client|
        'test value'
      end

      expect(result).to eq('test value')
    end

    it 'passes options to the client' do
      described_class.open(server_uri, timeout: 10, use_retransmission: false) do |client|
        expect(client.timeout).to eq(10)
        expect(client.instance_variable_get(:@use_retransmission)).to be false
      end
    end
  end

  describe '#closed?' do
    it 'returns false for a new client' do
      client = described_class.new(server_uri)
      expect(client.closed?).to be false
      client.close
    end

    it 'returns true after closing' do
      client = described_class.new(server_uri)
      client.close
      expect(client.closed?).to be true
    end
  end

  describe 'thread cleanup' do
    it 'prevents thread leaks when creating multiple clients' do
      initial_thread_count = Thread.list.size

      # Create and close multiple clients
      10.times do
        client = described_class.new(server_uri)
        client.close
      end

      # Give threads time to stop
      sleep 0.5

      # Should not have accumulated threads
      final_thread_count = Thread.list.size
      expect(final_thread_count).to be <= (initial_thread_count + 1) # Allow for small variance
    end

    it 'properly cleans up with the open pattern' do
      initial_thread_count = Thread.list.size

      # Create and auto-close multiple clients
      10.times do
        described_class.open(server_uri) do |_client|
          # Do nothing
        end
      end

      # Give threads time to stop
      sleep 0.5

      # Should not have accumulated threads
      final_thread_count = Thread.list.size
      expect(final_thread_count).to be <= (initial_thread_count + 1) # Allow for small variance
    end
  end

  describe '#exchange_simple' do
    let(:uri) { URI.parse(server_uri) }
    let(:message) { instance_double(Takagi::Message::Request, to_bytes: 'payload') }
    let(:socket) { instance_double(UDPSocket) }

    before do
      allow(UDPSocket).to receive(:new).and_return(socket)
      allow(socket).to receive(:send)
      allow(socket).to receive(:close)
      allow(socket).to receive(:closed?).and_return(false)
      allow(socket).to receive(:recvfrom)
    end

    it 'respects the configured timeout before reading a response' do
      client = described_class.new(server_uri, timeout: 0.25, use_retransmission: false)
      allow(socket).to receive(:wait_readable).with(0.25).and_return(false)
      allow(Takagi.logger).to receive(:warn)

      expect(client.send(:exchange_simple, message, uri)).to be_nil

      expect(Takagi.logger).to have_received(:warn).with(/timed out/)
      expect(socket).not_to have_received(:recvfrom)
      client.close
    end

    it 'returns the response once the socket becomes readable' do
      client = described_class.new(server_uri, timeout: 0.5, use_retransmission: false)
      allow(socket).to receive(:wait_readable).and_return(true)
      allow(socket).to receive(:recvfrom).and_return(['ok'])

      expect(client.send(:exchange_simple, message, uri)).to eq('ok')

      client.close
    end
  end

  describe 'default delivery' do
    it 'prints the response when no callback is registered' do
      payload = Takagi::Message::Outbound.new(code: '2.05', payload: 'Pong', token: '', type: 2).to_bytes
      socket = instance_double(UDPSocket, send: nil, close: nil, closed?: false, wait_readable: true, recvfrom: [payload])
      allow(UDPSocket).to receive(:new).and_return(socket)
      client = described_class.new(server_uri, timeout: 0.5, use_retransmission: false)

      expect { client.get('/ping') }.to output(/2\.05 Content.*Pong/).to_stdout

      client.close
    end
  end

  describe 'block-wise transfer over UDP' do
    def with_udp_server
      server = Takagi::Base.spawn!(port: 0, protocols: [:udp])
      port = bound_port_of(server)
      client = described_class.new("coap://127.0.0.1:#{port}", timeout: 10)
      yield(client)
    ensure
      client&.close
      server&.shutdown!
    end

    # Datagram count for one logical request, so a passing example proves the transfer
    # really was block-wise instead of fitting in a single request.
    def exchange_count(client)
      count = 0
      allow(client).to receive(:exchange).and_wrap_original do |original, *args|
        count += 1
        original.call(*args)
      end
      -> { count }
    end

    it 'fetches a Block2 response as successive NUMs and reassembles it into one payload' do
      with_udp_server do |client|
        exchanges = exchange_count(client)
        response = nil

        client.get('/client-block-wise/big') { |res| response = res }

        expect(response.content?).to be true
        expect(response.payload).to eq(big_representation)
        expect(response.payload.bytesize).to eq(4107)
        expect(exchanges.call).to eq(5)
        expect(response.options[Takagi::CoAP::Registries::Option::BLOCK2]).to be_nil
      end
    end

    it 'uploads a body larger than one block as a Block1 sequence' do
      with_udp_server do |client|
        exchanges = exchange_count(client)
        body = 'z' * 4096
        response = nil

        client.post('/client-block-wise/echo', body) { |res| response = res }

        expect(response.success?).to be true
        expect(exchanges.call).to eq(4)
        expect(JSON.parse(response.payload)).to eq('size' => 4096, 'digest' => Digest::SHA256.hexdigest(body))
      end
    end

    it 'surfaces a 4.13 as the response instead of hanging' do
      previous_cap = Takagi.config.block_wise.max_assembled_bytes
      Takagi.config.block_wise.max_assembled_bytes = 2048

      with_udp_server do |client|
        response = nil

        client.post('/client-block-wise/echo', 'z' * 4096) { |res| response = res }

        expect(response.request_entity_too_large?).to be true
      end
    ensure
      Takagi.config.block_wise.max_assembled_bytes = previous_cap
    end

    it 'raises when the server skips a Block2 NUM instead of returning partial data' do
      socket = UDPSocket.new
      socket.bind('127.0.0.1', 0)
      port = socket.addr[1]
      responder = Thread.new do
        [0, 2].each do |num|
          data, addr = socket.recvfrom(4096)
          value = Takagi::CoAP::BlockWise::OptionValue.encode(num: num, more: num.zero?, szx: 6)
          reply = Takagi::Message::Outbound.new(
            code: '2.05', payload: "block-#{num}", type: 2,
            token: data.byteslice(4, data.getbyte(0) & 0x0F),
            message_id: data.byteslice(2, 2).unpack1('n'),
            options: { Takagi::CoAP::Registries::Option::BLOCK2 => [value] }
          )
          socket.send(reply.to_bytes, 0, addr[3], addr[1])
        end
      end
      client = described_class.new("coap://127.0.0.1:#{port}", timeout: 2)

      expect do
        client.get('/x') { |res| res }
      end.to raise_error(Takagi::CoAP::BlockWise::IncompleteError, /block number 1/)
    ensure
      socket&.close
      responder&.join(2)
      client&.close
    end
  end

  describe 'reading the answer instead of the acknowledgement' do
    def peer_and_client(timeout:, responder:, use_retransmission: true)
      peer_socket = UDPSocket.new
      peer_socket.bind('127.0.0.1', 0)
      peer = Thread.new do
        next unless peer_socket.wait_readable(2)

        request, addr = peer_socket.recvfrom(4096)
        responder.call(request, peer_socket, addr)
      end
      client = described_class.new(
        "coap://127.0.0.1:#{peer_socket.addr[1]}",
        timeout: timeout,
        use_retransmission: use_retransmission
      )
      [client, peer, peer_socket]
    end

    def reply(socket, addr, bytes)
      socket.send(bytes, 0, addr[3], addr[1])
    end

    def request_message_id(request)
      request.byteslice(2, 2).unpack1('n')
    end

    def request_token(request)
      request.byteslice(4, request.getbyte(0) & 0x0F)
    end

    def empty_acknowledgement(message_id)
      [0x60, 0x00, message_id].pack('CCn')
    end

    def reset(message_id)
      [0x70, 0x00, message_id].pack('CCn')
    end

    def content(token, payload: 'Pong')
      [0x50 | token.bytesize, 0x45, 0x1234].pack('CCn') + token + "\xFF".b + payload
    end

    shared_examples 'an exchange that reads the answer' do |use_retransmission|
      it 'returns the response that follows an empty acknowledgement' do
        client, peer, peer_socket = peer_and_client(timeout: 3, use_retransmission: use_retransmission,
                                                    responder: lambda do |request, socket, addr|
                                                      reply(socket, addr, empty_acknowledgement(request_message_id(request)))
                                                      reply(socket, addr, content(request_token(request)))
                                                    end)
        response = nil

        client.get('/x') { |res| response = res }

        expect(response.content?).to be true
        expect(response.payload).to eq('Pong')
        expect(response.acknowledged_without_response?).to be false
      ensure
        peer&.join(1)
        peer_socket&.close
        client&.close
      end

      it 'keeps waiting when the peer only acknowledges, and times out' do
        client, peer, peer_socket = peer_and_client(timeout: 0.5, use_retransmission: use_retransmission,
                                                    responder: lambda do |request, socket, addr|
                                                      reply(socket, addr, empty_acknowledgement(request_message_id(request)))
                                                    end)
        response = nil

        expect(client.get('/x') { |res| response = res }).to be_nil
        expect(response).to be_nil
      ensure
        peer&.join(1)
        peer_socket&.close
        client&.close
      end

      it 'returns a Reset as the rejected response' do
        client, peer, peer_socket = peer_and_client(timeout: 3, use_retransmission: use_retransmission,
                                                    responder: lambda do |request, socket, addr|
                                                      reply(socket, addr, reset(request_message_id(request)))
                                                    end)
        response = nil

        started = Time.now
        client.get('/x') { |res| response = res }
        elapsed = Time.now - started

        expect(response.rejected?).to be true
        expect(elapsed).to be < 2.0
      ensure
        peer&.join(1)
        peer_socket&.close
        client&.close
      end
    end

    context 'with retransmission' do
      include_examples 'an exchange that reads the answer', true

      it 'returns a Reset that follows an empty acknowledgement without waiting out the timeout' do
        client, peer, peer_socket = peer_and_client(timeout: 3, responder: lambda do |request, socket, addr|
          reply(socket, addr, empty_acknowledgement(request_message_id(request)))
          reply(socket, addr, reset(request_message_id(request)))
        end)
        response = nil

        started = Time.now
        client.get('/x') { |res| response = res }
        elapsed = Time.now - started

        expect(response.rejected?).to be true
        expect(elapsed).to be < 2.0
      ensure
        peer&.join(1)
        peer_socket&.close
        client&.close
      end
    end

    context 'without retransmission' do
      include_examples 'an exchange that reads the answer', false
    end
  end

  describe '#ping' do
    # A UDP peer that answers the liveness probe the way `responder` says, and hands
    # back the exact bytes it received.
    def ping_peer(responder:)
      peer_socket = UDPSocket.new
      peer_socket.bind('127.0.0.1', 0)
      received = nil
      peer = Thread.new do
        next unless peer_socket.wait_readable(2)

        received, addr = peer_socket.recvfrom(4096)
        responder&.call(received, peer_socket, addr)
      end
      client = described_class.new(
        "coap://127.0.0.1:#{peer_socket.addr[1]}", timeout: 1, use_retransmission: false
      )
      [client, peer, peer_socket, -> { received }]
    end

    def reply(socket, addr, bytes)
      socket.send(bytes, 0, addr[3], addr[1])
    end

    def probe_message_id(probe)
      probe.byteslice(2, 2).unpack1('n')
    end

    def reset(message_id)
      [0x70, 0x00, message_id].pack('CCn')
    end

    def empty_acknowledgement(message_id)
      [0x60, 0x00, message_id].pack('CCn')
    end

    it 'probes with an Empty Confirmable message and reports a matching Reset as alive' do
      client, peer, peer_socket, probe = ping_peer(responder: lambda do |datagram, socket, addr|
        reply(socket, addr, reset(probe_message_id(datagram)))
      end)

      expect(client.ping).to be true
      peer.join(1)

      expect(probe.call.bytesize).to eq(4)
      expect(probe.call.getbyte(0)).to eq(0x40)
      expect(probe.call.getbyte(1)).to eq(0)
    ensure
      peer_socket&.close
      client&.close
    end

    it 'reports a peer that acknowledges instead of resetting the probe as not alive' do
      client, peer, peer_socket, = ping_peer(responder: lambda do |datagram, socket, addr|
        reply(socket, addr, empty_acknowledgement(probe_message_id(datagram)))
      end)

      expect(client.ping).to be false
    ensure
      peer&.join(1)
      peer_socket&.close
      client&.close
    end

    it 'reports a Reset carrying a different Message ID as not alive' do
      client, peer, peer_socket, = ping_peer(responder: lambda do |datagram, socket, addr|
        reply(socket, addr, reset((probe_message_id(datagram) + 1) & 0xFFFF))
      end)

      expect(client.ping).to be false
    ensure
      peer&.join(1)
      peer_socket&.close
      client&.close
    end

    it 'reports a silent peer as not alive, bounded by the timeout' do
      client, peer, peer_socket, = ping_peer(responder: nil)

      started = Time.now
      alive = client.ping
      elapsed = Time.now - started

      expect(alive).to be false
      expect(elapsed).to be >= 0.9
      expect(elapsed).to be < 2.5
    ensure
      peer&.join(1)
      peer_socket&.close
      client&.close
    end
  end

  describe 'a request typed as a Reset' do
    it 'refuses one carrying a payload instead of emitting a malformed Reset' do
      client = described_class.new(server_uri, timeout: 0.5, use_retransmission: false)

      expect { client.post('/echo', 'body', type: 3) }
        .to raise_error(Takagi::Network::Framing::EmptyMessageError, /bare header/)
    ensure
      client&.close
    end
  end
end
