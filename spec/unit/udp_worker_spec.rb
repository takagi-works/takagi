# frozen_string_literal: true

RSpec.describe Takagi::Server::UdpWorker do
  def build_worker(parent_pid:, shutdown:, sender: nil, logger: Takagi.logger)
    worker = described_class.new(
      socket: nil,
      middleware_stack: nil,
      router: nil,
      sender: sender,
      logger: logger,
      port: 5683,
      threads: 1
    )
    worker.instance_variable_set(:@parent_pid, parent_pid)
    worker.instance_variable_set(:@shutdown, shutdown)
    worker
  end

  def recording_logger(captured)
    logger = Object.new
    %i[debug warn error info].each do |level|
      logger.define_singleton_method(level) { |message| captured << message }
    end
    logger
  end

  def datagram(*bytes)
    bytes.pack('C*')
  end

  def with_message_id(first_byte, message_id)
    datagram(first_byte, 0x00, (message_id >> 8) & 0xFF, message_id & 0xFF)
  end

  def empty_con(message_id)
    with_message_id(0x40, message_id)
  end

  def empty_non(message_id)
    with_message_id(0x50, message_id)
  end

  def control_get(message_id)
    datagram(0x41, 0x01, (message_id >> 8) & 0xFF, message_id & 0xFF, 0x41, 0xB4, 0x70, 0x69, 0x6E, 0x67)
  end

  def immediate_response(worker, bytes)
    worker.send(:immediate_response, Takagi::Message::Inbound.new(bytes), bytes)
  end

  def await_datagram(socket, seconds)
    return nil unless socket.wait_readable(seconds)

    socket.recvfrom(4096).first
  end

  def drain(socket)
    socket.recvfrom(4096) while socket.wait_readable(0)
  end

  def await_server(socket, port)
    reply = nil
    40.times do |attempt|
      socket.send(control_get(0x3000 + attempt), 0, '127.0.0.1', port)
      reply = await_datagram(socket, 0.1)
      break if reply
    end
    reply
  end

  let(:worker) { build_worker(parent_pid: Process.ppid, shutdown: false) }

  describe '#stop_requested?' do
    it 'is true after a shutdown signal' do
      expect(build_worker(parent_pid: Process.ppid, shutdown: true).send(:stop_requested?)).to be(true)
    end

    it 'is true when the parent process is gone' do
      expect(build_worker(parent_pid: Process.ppid + 1, shutdown: false).send(:stop_requested?)).to be(true)
    end

    it 'is false while running under a live parent with no signal' do
      expect(build_worker(parent_pid: Process.ppid, shutdown: false).send(:stop_requested?)).to be(false)
    end
  end

  describe '#immediate_response' do
    it 'answers an Empty CON with a Reset echoing the Message ID' do
      reply = immediate_response(worker, empty_con(0x1234))

      expect(reply.type).to eq(3)
      expect(reply.code).to eq(0)
      expect(reply.message_id).to eq(0x1234)
      expect(reply.token).to eq(''.b)
      expect(reply.to_bytes).to eq(datagram(0x70, 0x00, 0x12, 0x34))
    end

    it 'answers an Empty NON with a Reset' do
      reply = immediate_response(worker, empty_non(0x2345))

      expect(reply.type).to eq(3)
      expect(reply.to_bytes).to eq(datagram(0x70, 0x00, 0x23, 0x45))
    end

    it 'rejects an Empty CON carrying a token without echoing the token' do
      reply = immediate_response(worker, datagram(0x41, 0x00, 0x34, 0x56, 0x61))

      expect(reply.type).to eq(3)
      expect(reply.token).to eq(''.b)
      expect(reply.to_bytes).to eq(datagram(0x70, 0x00, 0x34, 0x56))
    end

    it 'rejects an Empty CON carrying a trailing payload byte' do
      reply = immediate_response(worker, datagram(0x40, 0x00, 0x45, 0x67, 0x5A))

      expect(reply.type).to eq(3)
      expect(reply.to_bytes).to eq(datagram(0x70, 0x00, 0x45, 0x67))
    end

    it 'rejects a datagram with a reserved Token Length without echoing the token' do
      bytes = with_message_id(0x49, 0x5678) + ("\x01" * 9)
      reply = immediate_response(worker, bytes)

      expect(reply.type).to eq(3)
      expect(reply.token).to eq(''.b)
      expect(reply.to_bytes).to eq(datagram(0x70, 0x00, 0x56, 0x78))
    end

    it 'ignores a datagram whose version is not 1' do
      expect(immediate_response(worker, with_message_id(0x80, 0x6789))).to be_nil
    end

    it 'ignores an Empty ACK' do
      expect(immediate_response(worker, with_message_id(0x60, 0x789A))).to be_nil
    end

    it 'ignores an Empty RST' do
      expect(immediate_response(worker, with_message_id(0x70, 0x89AB))).to be_nil
    end

    it 'ignores a non-Empty GET so it reaches the middleware' do
      expect(immediate_response(worker, datagram(0x40, 0x01, 0x9A, 0xBC))).to be_nil
    end

    it 'logs the ignored type and Message ID' do
      captured = []
      logging_worker = build_worker(parent_pid: Process.ppid, shutdown: false, logger: recording_logger(captured))

      immediate_response(logging_worker, with_message_id(0x60, 0x1234))

      expect(captured.grep(/Ignoring/)).to include(a_string_matching(/MID: 4660/))
      expect(captured.grep(/Ignoring/)).to include(a_string_matching(/type: 2/))
    end
  end

  describe '#handle_request' do
    let(:addr) { ['AF_INET', 40_000, '127.0.0.1', '127.0.0.1'] }

    def sender_capturing(captured)
      sender = Object.new
      sender.define_singleton_method(:transmit) { |packet, _address, _port| captured << packet }
      sender
    end

    it 'sends byte-identical bytes for a retransmitted ping' do
      captured = []
      handling_worker = build_worker(parent_pid: Process.ppid, shutdown: false, sender: sender_capturing(captured))
      packet = empty_con(0x5150)

      handling_worker.send(:handle_request, packet, addr)
      handling_worker.send(:handle_request, packet, addr)

      expect(captured.size).to eq(2)
      bytes = captured.map { |sent| sent.is_a?(String) ? sent : sent.to_bytes }
      expect(bytes.uniq.size).to eq(1)
      expect(bytes.first).to eq(datagram(0x70, 0x00, 0x51, 0x50))
    end

    it 'does not route an ignored message to the middleware' do
      captured = []
      handling_worker = build_worker(parent_pid: Process.ppid, shutdown: false, sender: sender_capturing(captured))

      handling_worker.send(:handle_request, with_message_id(0x60, 0x6161), addr)

      expect(captured).to be_empty
    end

    it 'logs a ParseError naming the peer and the length, and replies with nothing, for a short datagram' do
      captured = []
      logs = []
      handling_worker = build_worker(parent_pid: Process.ppid, shutdown: false,
                                     sender: sender_capturing(captured), logger: recording_logger(logs))

      handling_worker.send(:handle_request, datagram(0x40, 0x00), addr)

      expect(captured).to be_empty
      expect(logs).to include(a_string_matching(/Takagi::Message::ParseError/))
      expect(logs).to include(a_string_matching(/127\.0\.0\.1:40000/))
      expect(logs).to include(a_string_matching(/\(2 bytes\)/))
      expect(logs.grep(/Handle_request failed/)).to be_empty
    end

    it 'keeps serving after a malformed datagram' do
      captured = []
      handling_worker = build_worker(parent_pid: Process.ppid, shutdown: false, sender: sender_capturing(captured))

      handling_worker.send(:handle_request, datagram(0x40), addr)
      handling_worker.send(:handle_request, empty_con(0x4242), addr)

      expect(captured.map { |sent| sent.is_a?(String) ? sent : sent.to_bytes })
        .to eq([datagram(0x70, 0x00, 0x42, 0x42)])
    end
  end

  describe 'wire level' do
    it 'answers a raw Empty CON with 70 00 <message id>' do
      server = Takagi::Base.spawn!(port: 0, protocols: [:udp])
      port = bound_port_of(server)
      socket = UDPSocket.new
      begin
        expect(await_server(socket, port)).to include('Pong')

        message_id = 0x4A17
        socket.send(empty_con(message_id), 0, '127.0.0.1', port)
        response = await_datagram(socket, 1.2)

        expect(response).to eq(datagram(0x70, 0x00, (message_id >> 8) & 0xFF, message_id & 0xFF))
      ensure
        socket.close
        server.shutdown!
      end
    end

    it 'ignores a short datagram and still answers the next request' do
      server = Takagi::Base.spawn!(port: 0, protocols: [:udp])
      port = bound_port_of(server)
      socket = UDPSocket.new
      begin
        expect(await_server(socket, port)).to include('Pong')
        drain(socket)

        socket.send(datagram(0x40, 0x00), 0, '127.0.0.1', port)
        expect(await_datagram(socket, 0.3)).to be_nil

        socket.send(control_get(0x4B11), 0, '127.0.0.1', port)
        expect(await_datagram(socket, 1.2)).to include('Pong')
      ensure
        socket.close
        server.shutdown!
      end
    end
  end
end
