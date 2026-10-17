# frozen_string_literal: true

require 'spec_helper'

# Plan row 4 (unified-cluster): the ONE bounded drain contract every transport shares. On
# TERM/INT a child stops accepting, finishes the in-flight work inside the drain deadline it
# DECLARES to the cluster, and only then leaves; the master's batch TERM->KILL deadline
# (`Cluster::WORKER_TERM_TIMEOUT`) is strictly larger than every one of those deadlines, so the
# KILL can never cut a drain that is still inside its promise.
#
# Every wait in this file is bounded and every wait waits on a real observable (a child pid, a
# socket, a byte on a pipe). The ONE fixed pause is the in-flight window of the proof below: the
# handler is held busy for 0.3 s on purpose, so that the stop provably lands while the exchange
# is unfinished - it is the condition under test, not a wait for a condition.
RSpec.describe 'Takagi drain contract (plan row 4)' do
  # The examples assert on real observables, never on log prose.
  class DrainNullLogger
    %i[debug info warn error].each { |level| define_method(level) { |_message| } }
  end

  # The in-flight handler: it announces itself on one pipe and blocks on the other until the
  # example releases it. Both pipes are created BEFORE the fork, so a forked child inherits both
  # ends of each and the release is an EVENT - a byte read - never a pause.
  class DrainGate
    def initialize(entered_w, release_r)
      @entered_w = entered_w
      @release_r = release_r
    end

    def call(_request)
      @entered_w.write('E')
      @entered_w.flush
      @release_r.read(1)
      'drained'
    end
  end

  # A CoAP CON GET, which the gate answers without ever reaching a router.
  def udp_request_bytes(message_id)
    [0x41, 0x01, (message_id >> 8) & 0xFF, message_id & 0xFF, 0x41, 0xB4, 0x70, 0x69, 0x6E, 0x67].pack('C*')
  end

  def tcp_request_bytes
    Takagi::Message::Outbound.new(
      code: 1, payload: nil, token: '12345678', options: { 11 => ['ping'] }, transport: :tcp
    ).to_bytes(transport: :tcp)
  end

  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  # Bounded wait on an observable: it returns the instant the block yields a value.
  def await(seconds)
    deadline = now + seconds
    loop do
      value = yield
      return value if value
      return nil if now >= deadline

      sleep 0.01
    end
  end

  def pid_state(pid)
    File.read("/proc/#{pid}/stat").rpartition(') ').last.split(' ', 2).first
  rescue Errno::ENOENT, Errno::ESRCH
    nil
  end

  def gone?(pid) = [nil, 'Z'].include?(pid_state(pid)) && !alive?(pid)

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  # Bounded wait until every child has EXITED - reaped or zombie, either way its drain and its
  # exit are over. THIS is the interval the row bounds, measured from the stop: how promptly the
  # master records the death afterwards is neither the child's drain nor the deadline under test.
  def await_children_exited(pids, seconds, since:)
    await(seconds) { pids.all? { |pid| gone?(pid) } ? now - since : nil }
  end

  # Watches the children from the stop onwards, so the exit instant stays honest even while this
  # process waits for a response that never comes.
  def watch_children_exit(pids, seconds, since:)
    Thread.new { await_children_exited(pids, seconds, since: since) }
  end

  def bound_port(server)
    socket = server.instance_variable_get(:@socket) || server.instance_variable_get(:@server)
    socket.addr[1]
  end

  # The adapter this transport DECLARES, through the public seam row 12 shipped. The reflection
  # this replaced read the serving cluster's first adapter, which is the UDP transport's - the
  # day two transports declare different deadlines it would have answered for the wrong one.
  def adapter_of(server) = server.adapter

  # The transport under test, built through its public constructor on a kernel-chosen port.
  # A nil gate leaves the server on its default middleware stack, which an idle server never
  # reaches anyway.
  def build_server(kind, gate = nil, processes: 2)
    logger = DrainNullLogger.new
    if kind == :udp
      Takagi::Server::Udp.new(port: 0, worker_processes: processes, worker_threads: 1,
                              middleware_stack: gate, logger: logger)
    else
      Takagi::Server::Tcp.new(port: 0, worker_processes: processes, worker_threads: 1,
                              middleware_stack: gate, logger: logger)
    end
  end

  # The client of each transport, driven from THIS process so the exchange crosses the fork.
  class DrainUdpClient
    def initialize(port)
      @socket = UDPSocket.new
      @socket.connect('127.0.0.1', port)
    end

    def send_request(bytes) = @socket.send(bytes, 0)

    def await_response(seconds)
      return nil unless @socket.wait_readable(seconds)

      @socket.recvfrom(65_535).first
    end

    def close = @socket.close
  end

  class DrainTcpClient
    def initialize(port) = (@socket = TCPSocket.new('127.0.0.1', port))

    def send_request(bytes)
      @socket.write(bytes)
      @socket.flush
    end

    # The server's CSM - and any Pong - are signalling frames; the first other frame is the
    # response.
    def await_response(seconds)
      deadline = now
      loop do
        left = (deadline + seconds) - now
        return nil unless left.positive? && @socket.wait_readable(left)

        raw = Takagi::Network::Framing::Tcp.read_from_socket(@socket)
        return nil unless raw
        return raw unless Takagi::CoAP::Registries::Signaling.signaling?(raw.getbyte(1))
      end
    end

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    def close = @socket.close
  end

  # Drives ONE exchange whose handler is held in flight, stops the server through its public
  # surface (which is the cluster's stop path: TERM each child, wait the batch deadline, KILL
  # only past it) and returns the measured facts. `release: false` leaves the handler blocked
  # for good, which is the bounded-drain case.
  def drive_stop_with_in_flight_exchange(kind, release: true)
    entered_r, entered_w = IO.pipe
    release_r, release_w = IO.pipe
    server = build_server(kind, DrainGate.new(entered_w, release_r))
    port = bound_port(server)
    runner = Thread.new { server.run! }
    pids = await(10) { list = server.worker_pids; list && list.size == 2 ? list.dup : nil }
    raise "#{kind}: no two worker children" unless pids

    # The client is built AFTER the children exist, so no worker inherits its socket: a client
    # fd that a forked worker also holds keeps the connection open past `close` - no FIN ever
    # reaches that worker's read - and the drain could then only end by signalling the handler
    # at its own deadline, a wait the deadline under test never asked for.
    client = (kind == :udp ? DrainUdpClient : DrainTcpClient).new(port)
    client.send_request(kind == :udp ? udp_request_bytes(0x7701) : tcp_request_bytes)
    in_flight = entered_r.wait_readable(5)
    entered_r.read(1) if in_flight

    stopper = Thread.new { server.shutdown! }
    stopped_at = now
    exit_watcher = watch_children_exit(pids, 5.0, since: stopped_at)
    sleep 0.3 # the SCENARIO: the stop lands while the handler is still busy
    if release
      release_w.write('R')
      release_w.flush
    end

    response = client.await_response(release ? 2.0 : 0.5)
    # The client leaves as soon as its exchange is over: what the drain must wait for is the
    # WORK, not a peer that idles with its connection open.
    client.close
    exit_elapsed = exit_watcher.value
    stopped = !stopper.join(5).nil?
    elapsed = now - stopped_at
    runner.join(5)
    { in_flight: !in_flight.nil?, response: response, stopped: stopped, elapsed: elapsed,
      exit_elapsed: exit_elapsed,
      pids: pids, deadline: adapter_of(server).drain_deadline,
      orphans: pids.reject { |pid| gone?(pid) } }
  end

  describe 'the two numbers and their order' do
    it 'declares each transport drain deadline strictly below the master batch deadline' do
      udp = Takagi::Server::Udp.new(port: 0, worker_processes: 2, worker_threads: 1)
      tcp = Takagi::Server::Tcp.new(port: 0, worker_processes: 2, worker_threads: 1)
      batch = Takagi::Server::Cluster::WORKER_TERM_TIMEOUT

      expect(batch).to be > 0
      expect(adapter_of(udp).drain_deadline).to eq(Takagi::Server::Udp::DRAIN_DEADLINE)
      expect(adapter_of(tcp).drain_deadline).to eq(Takagi::Server::Tcp::POOL_JOIN_TIMEOUT)
      # The declaration and the join are ONE value for UDP: the worker's own constant.
      expect(Takagi::Server::Udp::DRAIN_DEADLINE).to eq(Takagi::Server::UdpWorker::DRAIN_DEADLINE)
      [udp, tcp].each do |server|
        expect(adapter_of(server).drain_deadline).to be < batch
      end
    ensure
      udp&.shutdown!
      tcp&.shutdown!
    end

    # The ordering rule is enforced in CODE, not left as prose in two files: a service whose
    # adapter could drain past the master's batch deadline is refused before it forks anything.
    it 'refuses a cluster whose adapter could drain past the master batch deadline' do
      batch = Takagi::Server::Cluster::WORKER_TERM_TIMEOUT
      logger = DrainNullLogger.new
      stub = Struct.new(:drain_deadline)

      [batch, batch + 1.0].each do |deadline|
        expect { Takagi::Server::Cluster.new(count: 2, adapters: [stub.new(deadline)], logger: logger) }
          .to raise_error(ArgumentError, /drain_deadline #{Regexp.escape(deadline.to_s)}s.*#{Regexp.escape(batch.to_s)}s/)
      end

      # Strictly below is accepted, and an adapter with no in-flight window to protect is not
      # asked for one.
      expect { Takagi::Server::Cluster.new(count: 2, adapters: [stub.new(batch - 0.5)], logger: logger) }
        .not_to raise_error
      expect { Takagi::Server::Cluster.new(count: 2, adapters: [stub.new(nil)], logger: logger) }
        .not_to raise_error
    end
  end

  describe 'an in-flight exchange survives the stop' do
    it 'UDP: answers the datagram the stop arrived in the middle of, and the child leaves inside the deadline' do
      result = drive_stop_with_in_flight_exchange(:udp)

      expect(result[:in_flight]).to be(true)
      expect(result[:response]).to include('drained')
      expect(result[:stopped]).to be(true)
      expect(result[:orphans]).to be_empty
      expect(result[:exit_elapsed]).not_to be_nil, 'the children never exited'
      expect(result[:exit_elapsed]).to be <= (result[:deadline] + 0.6),
                                      "the children took #{result[:exit_elapsed].round(3)} s to exit, past the " \
                                      "declared #{result[:deadline]} s deadline"
    end

    it 'TCP: answers the connection the stop arrived in the middle of, and the child leaves inside the deadline' do
      result = drive_stop_with_in_flight_exchange(:tcp)

      expect(result[:in_flight]).to be(true)
      expect(result[:response]).to include('drained')
      expect(result[:stopped]).to be(true)
      expect(result[:orphans]).to be_empty
      expect(result[:exit_elapsed]).not_to be_nil, 'the children never exited'
      expect(result[:exit_elapsed]).to be <= (result[:deadline] + 0.6)
    end
  end

  # The multi-transport shape: ONE cluster, TWO adapters, `processes > 1`. A child of such a
  # service serves both transport loops on its own threads, and the join that closes that serve
  # phase is where a drain still inside its declared deadline was once cut.
  def drive_multi_transport_stop(transport:, release_after: 0.8)
    entered_r, entered_w = IO.pipe
    release_r, release_w = IO.pipe
    gate = DrainGate.new(entered_w, release_r)
    udp = Takagi::Server::Udp.new(port: 0, worker_processes: 3, worker_threads: 1,
                                  middleware_stack: gate, logger: DrainNullLogger.new)
    tcp = Takagi::Server::Tcp.new(port: 0, worker_processes: 3, worker_threads: 1,
                                  middleware_stack: gate, logger: DrainNullLogger.new)
    port = transport == :udp ? bound_port(udp) : bound_port(tcp)
    service = Takagi::Server::Multi.new([udp, tcp], protocols: %i[udp tcp], logger: DrainNullLogger.new)
    runner = Thread.new { service.run! }
    pids = await(15) { list = service.worker_pids; list && list.size == 3 ? list.dup : nil }
    raise "#{transport}: no three worker children" unless pids

    # Built after the fork for the same reason as the single-transport helper above: the client
    # must be a peer no worker holds a copy of, or its `close` never ends the connection.
    client = transport == :udp ? DrainUdpClient.new(port) : DrainTcpClient.new(port)
    client.send_request(transport == :udp ? udp_request_bytes(0x7702) : tcp_request_bytes)
    in_flight = entered_r.wait_readable(5)
    entered_r.read(1) if in_flight
    stopper = Thread.new { service.shutdown! }
    stopped_at = now
    exit_watcher = watch_children_exit(pids, 6.0, since: stopped_at)
    sleep release_after # the SCENARIO: still inside the 1.0 s drain both transports declare
    release_w.write('R')
    release_w.flush
    response = client.await_response(2.0)
    client.close
    exit_elapsed = exit_watcher.value
    stopped = !stopper.join(8).nil?
    runner.join(5)
    { in_flight: !in_flight.nil?, response: response, stopped: stopped, exit_elapsed: exit_elapsed,
      deadline: adapter_of(tcp).drain_deadline, orphans: pids.reject { |pid| gone?(pid) } }
  end

  describe 'a multi-transport child' do
    it 'drains an in-flight UDP exchange inside the deadline, past the poll interval the join once spent' do
      result = drive_multi_transport_stop(transport: :udp)

      expect(result[:in_flight]).to be(true)
      expect(result[:response]).to include('drained')
      expect(result[:stopped]).to be(true)
      expect(result[:orphans]).to be_empty
      expect(result[:exit_elapsed]).not_to be_nil, 'the children never exited'
      expect(result[:exit_elapsed]).to be <= (result[:deadline] + 0.6),
                                      "the children took #{result[:exit_elapsed].round(3)} s to exit, past the " \
                                      "declared #{result[:deadline]} s deadline"
    end

    it 'drains an in-flight TCP exchange inside the deadline, past the poll interval the join once spent' do
      result = drive_multi_transport_stop(transport: :tcp)

      expect(result[:in_flight]).to be(true)
      expect(result[:response]).to include('drained')
      expect(result[:stopped]).to be(true)
      expect(result[:orphans]).to be_empty
      expect(result[:exit_elapsed]).not_to be_nil, 'the children never exited'
      expect(result[:exit_elapsed]).to be <= (result[:deadline] + 0.6)
    end
  end

  describe 'the drain is bounded, never unbounded' do
    it 'UDP: signals a handler that never finishes at the deadline instead of waiting on it' do
      result = drive_stop_with_in_flight_exchange(:udp, release: false)
      batch = Takagi::Server::Cluster::WORKER_TERM_TIMEOUT

      expect(result[:in_flight]).to be(true)
      # The stuck handler never produced a response - and the STOP still ended: the drain
      # waited out its own deadline (no less) and then signalled the straggler, so the master
      # never had to KILL a child that was still draining inside its contract.
      expect(result[:response]).to be_nil
      expect(result[:stopped]).to be(true)
      expect(result[:orphans]).to be_empty
      expect(result[:exit_elapsed]).not_to be_nil, 'the children never exited'
      expect(result[:exit_elapsed]).to be >= (result[:deadline] - 0.05)
      expect(result[:exit_elapsed]).to be < batch,
                                      "the children took #{result[:exit_elapsed].round(3)} s to exit, at or past the " \
                                      "batch deadline #{batch} s: the KILL, not the drain, ended it"
    end
  end

  describe 'an idle worker' do
    it 'exits far faster than the deadline it declares' do
      %i[udp tcp].each do |kind|
        server = build_server(kind)
        deadline = adapter_of(server).drain_deadline
        runner = Thread.new { server.run! }
        pids = await(10) { list = server.worker_pids; list && list.size == 2 ? list.dup : nil }
        raise "#{kind}: no two idle workers" unless pids

        stopped_at = now
        server.shutdown!
        elapsed = now - stopped_at
        runner.join(5)

        expect(pids.reject { |pid| gone?(pid) }).to be_empty
        expect(elapsed).to be < deadline, "idle #{kind} stop took #{elapsed.round(3)} s against a #{deadline} s deadline"
      end
    end
  end

  # Plan row 13 (GAP-17): the shape `worker_threads` unset hands TCP - one thread per accepted
  # connection, no pool - reached `exit!(0)` with its handlers still working, so an in-flight
  # exchange was LOST on stop. That is the DEFAULT shape a TCP service gets: the pool opens only
  # on the protocol's OWN `threads` key (server_lifecycle.rb `per_protocol_threads?`), never on
  # an untouched global default. The same declared drain now joins these threads too.
  describe 'the non-pooled TCP shape (plan row 13)' do
    # No pool: every accepted connection runs on a thread of its own.
    def nonpooled_tcp(gate, processes: 2)
      Takagi::Server::Tcp.new(port: 0, worker_processes: processes, middleware_stack: gate,
                              logger: DrainNullLogger.new)
    end

    # The pooled helper's driver with the pool left OFF: ONE exchange held in flight while the
    # stop lands, released `release_after` seconds later. The client is created AFTER the children
    # exist for the reason documented there - a client socket the workers inherited would keep the
    # connection open past `close`, so the serving child would never see EOF.
    def drive_nonpooled_in_flight(release: true, release_after: 0.2)
      entered_r, entered_w = IO.pipe
      release_r, release_w = IO.pipe
      server = nonpooled_tcp(DrainGate.new(entered_w, release_r))
      port = bound_port(server)
      runner = Thread.new { server.run! }
      pids = await(10) { list = server.worker_pids; list && list.size == 2 ? list.dup : nil }
      raise 'tcp: no two worker children' unless pids

      client = DrainTcpClient.new(port)
      client.send_request(tcp_request_bytes)
      in_flight = entered_r.wait_readable(5)
      entered_r.read(1) if in_flight

      stopper = Thread.new { server.shutdown! }
      stopped_at = now
      exit_watcher = watch_children_exit(pids, 5.0, since: stopped_at)
      sleep release_after # the SCENARIO: the stop lands while the handler is still busy
      if release
        release_w.write('R')
        release_w.flush
      end

      response = client.await_response(release ? 2.0 : 1.5)
      client.close
      exit_elapsed = exit_watcher.value
      stopped = !stopper.join(5).nil?
      runner.join(5)
      { in_flight: !in_flight.nil?, response: response, stopped: stopped, exit_elapsed: exit_elapsed,
        deadline: adapter_of(server).drain_deadline,
        orphans: pids.reject { |pid| gone?(pid) } }
    end

    it 'answers the connection the stop arrived in the middle of, and the child leaves inside the deadline' do
      result = drive_nonpooled_in_flight

      expect(result[:in_flight]).to be(true)
      expect(result[:response]).to include('drained'),
                                    "the in-flight response was lost (#{result[:response].inspect}); the children " \
                                    "were gone at #{result[:exit_elapsed].inspect} s, against a declared " \
                                    "#{result[:deadline]} s drain"
      expect(result[:stopped]).to be(true)
      expect(result[:orphans]).to be_empty
      expect(result[:exit_elapsed]).not_to be_nil, 'the children never exited'
      expect(result[:exit_elapsed]).to be <= (result[:deadline] + 0.6)
    end

    it 'signals a non-pooled handler that never finishes at the deadline instead of waiting on it' do
      result = drive_nonpooled_in_flight(release: false)
      batch = Takagi::Server::Cluster::WORKER_TERM_TIMEOUT

      expect(result[:in_flight]).to be(true)
      # The stuck handler never produced a response - and the STOP still ended, once the drain had
      # waited out its own deadline and signalled the straggler: the join is bounded, never endless.
      expect(result[:response]).to be_nil
      expect(result[:stopped]).to be(true)
      expect(result[:orphans]).to be_empty
      expect(result[:exit_elapsed]).not_to be_nil, 'the children never exited'
      expect(result[:exit_elapsed]).to be >= (result[:deadline] - 0.05)
      expect(result[:exit_elapsed]).to be < batch,
                                      "the children took #{result[:exit_elapsed].round(3)} s to exit, at or past " \
                                      "the batch deadline #{batch} s: the KILL, not the drain, ended it"
    end

    it 'leaves an idle non-pooled worker far faster than the deadline it declares' do
      server = nonpooled_tcp(nil)
      deadline = adapter_of(server).drain_deadline
      runner = Thread.new { server.run! }
      pids = await(10) { list = server.worker_pids; list && list.size == 2 ? list.dup : nil }
      raise 'tcp: no two idle workers' unless pids

      stopped_at = now
      server.shutdown!
      elapsed = now - stopped_at
      runner.join(5)

      expect(pids.reject { |pid| gone?(pid) }).to be_empty
      expect(elapsed).to be < deadline,
                          "idle non-pooled tcp stop took #{elapsed.round(3)} s against a #{deadline} s deadline"
    end
  end
end
