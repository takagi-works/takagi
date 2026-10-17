# frozen_string_literal: true

require 'digest'
require 'json'

RSpec.describe Takagi::TcpClient do
  def with_tcp_server
    server = Takagi::Base.spawn!(port: 0, protocols: [:tcp])
    port = bound_port_of(server)
    client = described_class.new("coap+tcp://127.0.0.1:#{port}", timeout: 10)
    yield(client)
  ensure
    client&.close
    server&.shutdown!
  end

  it 'sends request and receives response over TCP' do
    server = Takagi::Base.spawn!(port: 0, protocols: [:tcp])
    port = bound_port_of(server)
    client = described_class.new("coap+tcp://127.0.0.1:#{port}")

    response = nil
    client.get('/ping') { |res| response = res }

    expect(response).to be_a(Takagi::Client::Response)
    expect(response.payload).to include('Pong')
    expect(response.success?).to be true
  ensure
    client&.close
    server.shutdown!
  end

  describe 'CSM handshake (RFC 8323 §3.3)' do
    def csm_frame
      Takagi::Message::Outbound.new(
        code: Takagi::CoAP::Registries::Signaling::CSM,
        payload: '', token: '', message_id: 0, type: 0,
        options: { 2 => [8_388_864] }, transport: :tcp
      ).to_bytes(transport: :tcp)
    end

    def content_frame(token:)
      Takagi::Message::Outbound.new(
        code: Takagi::CoAP::Registries::Response::CONTENT,
        payload: 'ok', token: token, message_id: 0, type: 0,
        options: {}, transport: :tcp
      ).to_bytes(transport: :tcp)
    end

    it 'sends its own CSM first and skips the peer CSM to return the real response' do
      server = TCPServer.new('127.0.0.1', 0)
      port = server.addr[1]
      inbound = nil
      peer = Thread.new do
        conn = server.accept
        inbound = Array.new(2) { Takagi::Network::Framing::Tcp.read_from_socket(conn) }
        request = Takagi::Network::Framing::Tcp.decode(inbound[1])
        conn.write(csm_frame)
        conn.write(content_frame(token: request.token))
        conn.close
      end

      response = nil
      client = described_class.new("coap+tcp://127.0.0.1:#{port}", timeout: 5)
      client.get('/x') { |res| response = res }
      peer.join(5)

      expect(peer).not_to be_alive
      expect(Takagi::Network::Framing::Tcp.decode(inbound[0]).code)
        .to eq(Takagi::CoAP::Registries::Signaling::CSM)
      expect(response).to be_a(Takagi::Client::Response)
      expect(response.code_name).to eq('2.05 Content')
      expect(response.payload).to eq('ok')
    ensure
      server&.close
      client&.close
    end

    it 'returns nil within its timeout when the peer sends only a CSM' do
      server = TCPServer.new('127.0.0.1', 0)
      port = server.addr[1]
      release = Queue.new
      peer = Thread.new do
        conn = server.accept
        2.times { Takagi::Network::Framing::Tcp.read_from_socket(conn) }
        conn.write(csm_frame)
        release.pop
        conn.close
      end

      client = described_class.new("coap+tcp://127.0.0.1:#{port}", timeout: 1)
      expect(client.get('/x')).to be_nil
    ensure
      release&.push(:done)
      peer&.join(5)
      server&.close
      client&.close
    end

    it 'returns nil rather than hanging when the peer closes mid-exchange' do
      server = TCPServer.new('127.0.0.1', 0)
      port = server.addr[1]
      peer = Thread.new do
        conn = server.accept
        2.times { Takagi::Network::Framing::Tcp.read_from_socket(conn) }
        conn.write(csm_frame)
        conn.close
      end

      client = described_class.new("coap+tcp://127.0.0.1:#{port}", timeout: 5)
      expect(client.get('/x')).to be_nil
      peer.join(5)
    ensure
      server&.close
      client&.close
    end

    it 'returns nil at its deadline when the peer announces a body it never sends' do
      server = TCPServer.new('127.0.0.1', 0)
      port = server.addr[1]
      peer = Thread.new do
        conn = server.accept
        2.times { Takagi::Network::Framing::Tcp.read_from_socket(conn) }
        conn.write("\x50".b)  # length nibble 5, token length 0: five body bytes announced
        conn.wait_readable(4) # ...and the connection held open with none of them sent
        conn.close
      end

      client = described_class.new("coap+tcp://127.0.0.1:#{port}", timeout: 1)
      started = Time.now
      result = client.get('/x')
      elapsed = Time.now - started
      peer.join(5)

      expect(result).to be_nil
      expect(elapsed).to be >= 0.9
      # The peer holds for 4s, so an elapsed time near it means the deadline never reached
      # the body read and only the peer's own close ended the exchange.
      expect(elapsed).to be < 2.5
    ensure
      server&.close
      client&.close
    end

    it 'returns the response when the peer delivers its body in two parts inside the timeout' do
      server = TCPServer.new('127.0.0.1', 0)
      port = server.addr[1]
      peer = Thread.new do
        conn = server.accept
        request = Takagi::Network::Framing::Tcp.decode(
          Array.new(2) { Takagi::Network::Framing::Tcp.read_from_socket(conn) }.last
        )
        frame = content_frame(token: request.token)
        conn.write(frame.byteslice(0, 2))
        conn.write(frame.byteslice(2, frame.bytesize - 2))
        conn.wait_readable(2)
        conn.close
      end

      client = described_class.new("coap+tcp://127.0.0.1:#{port}", timeout: 5)
      started = Time.now
      response = client.get('/x')
      elapsed = Time.now - started
      peer.join(5)

      expect(response).to be_a(Takagi::Client::Response)
      expect(response.code_name).to eq('2.05 Content')
      expect(response.payload).to eq('ok')
      expect(elapsed).to be < 1.0
    ensure
      server&.close
      client&.close
    end

    it 'returns nil when four signalling frames arrive before the response' do
      server = TCPServer.new('127.0.0.1', 0)
      port = server.addr[1]
      peer = Thread.new do
        conn = server.accept
        request = Takagi::Network::Framing::Tcp.decode(
          Array.new(2) { Takagi::Network::Framing::Tcp.read_from_socket(conn) }.last
        )
        4.times { conn.write(csm_frame) }
        conn.write(content_frame(token: request.token))
        conn.wait_readable(2)
        conn.close
      end

      client = described_class.new("coap+tcp://127.0.0.1:#{port}", timeout: 3)
      started = Time.now
      result = client.get('/x')
      elapsed = Time.now - started
      peer.join(5)

      expect(result).to be_nil
      # The frame allowance, not the deadline, has to end this read: the response is already
      # buffered, so waiting for the 3s deadline would mean the bound stopped working.
      expect(elapsed).to be < 1.5
    ensure
      server&.close
      client&.close
    end
  end

  describe 'large payloads over TCP' do
    it 'returns a representation larger than one block in a single exchange' do
      with_tcp_server do |client|
        exchanges = 0
        allow(client).to receive(:exchange).and_wrap_original do |original, *args|
          exchanges += 1
          original.call(*args)
        end
        response = nil

        client.get('/client-block-wise/big') { |res| response = res }

        expect(response.payload).to eq(big_representation)
        expect(response.payload.bytesize).to eq(4107)
        expect(exchanges).to eq(1)
      end
    end

    it 'posts a 4 KiB body that the handler receives whole' do
      with_tcp_server do |client|
        body = 'z' * 4096
        response = nil

        client.post('/client-block-wise/echo', body) { |res| response = res }

        expect(response.success?).to be true
        expect(JSON.parse(response.payload)).to eq('size' => 4096, 'digest' => Digest::SHA256.hexdigest(body))
      end
    end
  end

  describe 'lifecycle management' do
    it 'has close method' do
      client = described_class.new('coap+tcp://127.0.0.1:5683')
      expect(client).to respond_to(:close)
      expect(client).to respond_to(:closed?)
      client.close
    end

    it 'supports block-based auto-close' do
      result = described_class.open('coap+tcp://127.0.0.1:5683') do |client|
        expect(client.closed?).to be false
        'test_result'
      end

      expect(result).to eq('test_result')
    end
  end

  describe '#ping' do
    def pong_frame(token)
      Takagi::Message::Outbound.new(
        code: Takagi::CoAP::Registries::Signaling::PONG,
        payload: '', token: token, message_id: 0, type: 0, transport: :tcp
      ).to_bytes(transport: :tcp)
    end

    def ping_csm_frame
      Takagi::Message::Outbound.new(
        code: Takagi::CoAP::Registries::Signaling::CSM,
        payload: '', token: '', message_id: 0, type: 0,
        options: { 2 => [8_388_864] }, transport: :tcp
      ).to_bytes(transport: :tcp)
    end

    def free_tcp_port
      server = TCPServer.new('127.0.0.1', 0)
      port = server.addr[1]
      server.close
      port
    end

    it 'sends its CSM and a Ping, and reports a Pong carrying the same token as alive' do
      server = TCPServer.new('127.0.0.1', 0)
      seen = nil
      peer = Thread.new do
        conn = server.accept
        csm = Takagi::Network::Framing::Tcp.read_from_socket(conn)
        ping = Takagi::Network::Framing::Tcp.read_from_socket(conn)
        request = Takagi::Network::Framing::Tcp.decode(ping)
        seen = { first: Takagi::Network::Framing::Tcp.decode(csm).code, second: request.code }
        conn.write(ping_csm_frame)
        conn.write(pong_frame(request.token))
        conn.close
      end

      client = described_class.new("coap+tcp://127.0.0.1:#{server.addr[1]}", timeout: 2)
      expect(client.ping).to be true
      peer.join(2)

      expect(seen[:first]).to eq(Takagi::CoAP::Registries::Signaling::CSM)
      expect(seen[:second]).to eq(Takagi::CoAP::Registries::Signaling::PING)
    ensure
      server&.close
      client&.close
    end

    it 'reports a Pong carrying a different token as not alive' do
      server = TCPServer.new('127.0.0.1', 0)
      peer = Thread.new do
        conn = server.accept
        2.times { Takagi::Network::Framing::Tcp.read_from_socket(conn) }
        conn.write(ping_csm_frame)
        conn.write(pong_frame('mismatched'))
        conn.close
      end

      client = described_class.new("coap+tcp://127.0.0.1:#{server.addr[1]}", timeout: 2)
      expect(client.ping).to be false
      peer.join(2)
    ensure
      server&.close
      client&.close
    end

    it 'reports a closed port as not alive instead of raising' do
      client = described_class.new("coap+tcp://127.0.0.1:#{free_tcp_port}", timeout: 1)

      expect(client.ping).to be false
    ensure
      client&.close
    end

    it 'reports a peer that closes mid-probe as not alive' do
      server = TCPServer.new('127.0.0.1', 0)
      peer = Thread.new do
        conn = server.accept
        2.times { Takagi::Network::Framing::Tcp.read_from_socket(conn) }
        conn.close
      end

      client = described_class.new("coap+tcp://127.0.0.1:#{server.addr[1]}", timeout: 2)
      expect(client.ping).to be false
      peer.join(2)
    ensure
      server&.close
      client&.close
    end

    it 'reports a silent peer as not alive, bounded by the timeout' do
      server = TCPServer.new('127.0.0.1', 0)
      release = Queue.new
      peer = Thread.new do
        conn = server.accept
        2.times { Takagi::Network::Framing::Tcp.read_from_socket(conn) }
        conn.write(ping_csm_frame)
        release.pop
        conn.close
      end

      client = described_class.new("coap+tcp://127.0.0.1:#{server.addr[1]}", timeout: 1)
      started = Time.now
      alive = client.ping
      elapsed = Time.now - started

      expect(alive).to be false
      expect(elapsed).to be >= 0.9
      expect(elapsed).to be < 2.5
    ensure
      release&.push(:done)
      peer&.join(2)
      server&.close
      client&.close
    end
  end
end
