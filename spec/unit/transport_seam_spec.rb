# frozen_string_literal: true

require 'stringio'

# Row 12 of .omo/plans/unified-cluster.md: the transport seam, the stale readers and udp's own
# payload.
#
# A service supervises several transports through ONE cluster, and needs each transport to say
# what it will serve without being reached into: `#adapter` (the declaration the cluster supervises
# a transport through), `#bound_port` (what that transport's OWN socket bound),
# `#start_service_hooks!` (what a serving process must start before the fork) and
# `#supervised_by(cluster)` (adopt a cluster this server did not build). The last one is what keeps
# the readers honest: every transport of a service points at the ONE cluster that supervises that
# service, so `srv.cluster`/`srv.worker_pids` can never report a replaced per-transport cluster -
# while `#shutdown!` on one transport stops only that transport.
RSpec.describe 'the transport seam (plan row 12)' do
  # Boots ONE transport through its public constructor, capturing its own `:server_starting`
  # payload (the emit lives in #run!, so the subscription is armed before the server starts and
  # stays armed until the payload is in hand).
  def boot_transport(protocol)
    queue = Queue.new
    handler = Takagi::Hooks.subscribe(:server_starting) { |payload| queue << payload }
    server = build_transport(protocol)
    Thread.new { server.run! }
    [server, Timeout.timeout(5) { queue.pop }]
  ensure
    Takagi::Hooks.unsubscribe(:server_starting, handler) if handler
  end

  def build_transport(protocol)
    case protocol
    when :udp then Takagi::Server::Udp.new(port: 0, worker_processes: 1, worker_threads: 1)
    when :tcp then Takagi::Server::Tcp.new(port: 0, worker_processes: 1, worker_threads: 1)
    else raise ArgumentError, "unknown transport #{protocol.inspect}"
    end
  end

  # Boots a SERVICE through the public API with the boot/stop hooks armed BEFORE it boots, yields
  # [service, surface payload, transport-start queue, transport-stop queue], and tears everything
  # down afterwards. The subscriptions outlive the boot because the transports' own payloads come
  # from the service's run thread, asynchronously.
  def with_service(protocols: %i[udp tcp])
    starts = Queue.new
    stops = Queue.new
    surface = Queue.new
    handlers = {
      server_starting: Takagi::Hooks.subscribe(:server_starting) { |payload| starts << payload },
      server_stopped: Takagi::Hooks.subscribe(:server_stopped) { |payload| stops << payload },
      service_starting: Takagi::Hooks.subscribe(:service_starting) { |payload| surface << payload }
    }
    log = StringIO.new
    original = $stdout
    $stdout = log
    service = begin
      Takagi::Base.spawn!(port: 0, protocols: protocols)
    ensure
      $stdout = original
    end
    yield service, Timeout.timeout(5) { surface.pop }, starts, stops
  ensure
    handlers&.each { |event, handler| Takagi::Hooks.unsubscribe(event, handler) }
    service&.shutdown!
  end

  def exchange(scheme, protocol, port)
    client = Takagi::Client.new("#{scheme}://127.0.0.1:#{port}", protocol: protocol, timeout: 10)
    responses = Queue.new
    client.get('/ping') { |response| responses << response }
    Timeout.timeout(10) { responses.pop }.payload
  ensure
    client&.close
  end

  # Drains `count` payloads off a queue, so a missing event fails as a bounded timeout rather than
  # as a silent hang.
  def take(queue, count)
    Array.new(count) { Timeout.timeout(5) { queue.pop } }
  end

  it 'reads each bound port off the transport own socket, and exposes the adapter (PROOF)' do
    tcp = build_transport(:tcp)
    udp = build_transport(:udp)

    # The oracle is the socket itself (spec_helper reads it off `@server`/`@socket`), so this can
    # only pass if the seam reports the port the SAME socket holds.
    [tcp, udp].each do |server|
      expect(server.bound_port).to eq(bound_port_of(server))
      expect(server.bound_port).to be_positive
      expect(server.adapter.fds.first.addr[1]).to eq(server.bound_port)
    end
    expect(udp.bound_port).not_to eq(tcp.bound_port)

    expect(tcp.adapter).to respond_to(:fds, :serve_loop, :stop_requested?, :stop!, :prepare_process,
                                      :unit_of_work, :thread_count, :admission_cap, :drain_deadline)
    expect(udp.adapter.unit_of_work).to eq(:datagram)
    expect(tcp.adapter.unit_of_work).to eq(:connection)
    # ONE declaration per transport: the adapter the seam exposes is the one the server's own
    # cluster was built with, so what a service supervises and what the reader reports cannot drift.
    [tcp, udp].each { |server| expect(server.cluster.instance_variable_get(:@adapters)).to eq([server.adapter]) }
  ensure
    tcp&.shutdown!
    udp&.shutdown!
  end

  it 'reports the port the UDP socket actually bound in udp own :server_starting payload (PROOF)' do
    server, payload = boot_transport(:udp)

    # The port must be the socket's own: `port: 0` lets the kernel choose one, so a payload
    # carrying the requested 0 would name a port nobody holds. The oracle here is the socket
    # (spec_helper), not the seam, so the discriminator is the payload VALUE alone.
    expect(bound_port_of(server)).to be_positive
    expect(payload[:port]).to eq(bound_port_of(server))
    expect(payload[:protocol]).to eq(:udp)
  ensure
    server&.shutdown!
  end

  it 'keeps the shipped :server_starting keys and their meaning for ONE transport (GUARD)' do
    udp, udp_payload = boot_transport(:udp)
    tcp, tcp_payload = boot_transport(:tcp)

    [udp_payload, tcp_payload].each { |payload| expect(payload.keys.map(&:to_sym).sort).to eq(%i[port protocol]) }
    expect(udp_payload[:protocol]).to eq(:udp)
    expect(tcp_payload[:protocol]).to eq(:tcp)
    # `:port` is a port number on both transports; TCP has always reported the port its listener
    # bound, and UDP's payload stays additive - the same keys, never a renamed or dropped one.
    expect(tcp_payload[:port]).to eq(bound_port_of(tcp))
    expect(udp_payload[:port]).to be_a(Integer)
    expect(udp_payload[:port]).to be >= 0
  ensure
    udp&.shutdown!
    tcp&.shutdown!
  end

  it 'points every transport of a service at the ONE cluster that supervises it (PROOF)' do
    with_service do |service, _surface, _starts, _stops|
      udp, tcp = service.servers

      expect(udp.cluster).to be(service.cluster)
      expect(tcp.cluster).to be(service.cluster)

      # Which reader is authoritative: `Multi#worker_pids`, the service-level one. Feeding the
      # service cluster a pid list (the state its own supervision keeps) shows the per-transport
      # readers report THAT list - they read the supervisor, so a per-transport cluster that
      # serves nothing could not answer them.
      allow(service.cluster).to receive(:worker_pids).and_return(%w[10 11 12])
      expect(service.worker_pids).to eq(%w[10 11 12])
      expect(udp.worker_pids).to eq(%w[10 11 12])
      expect(tcp.worker_pids).to eq(%w[10 11 12])
    end
  end

  it 'reports each transport own bound port on the service surface and in its :server_starting (GUARD)' do
    with_service do |service, surface, starts, _stops|
      udp, tcp = service.servers

      expect(surface[:protocols]).to eq(%i[udp tcp])
      expect(surface[:ports]).to eq(udp: bound_port_of(udp), tcp: bound_port_of(tcp))
      expect(surface[:ports].values).to all(be_positive)

      by_protocol = take(starts, 2).to_h { |payload| [payload[:protocol].to_sym, payload[:port]] }
      expect(by_protocol).to eq(udp: bound_port_of(udp), tcp: bound_port_of(tcp))
    end
  end

  it 'emits :server_stopped for BOTH transports of a service (PROOF)' do
    with_service do |service, _surface, _starts, stops|
      udp, tcp = service.servers
      udp_port, tcp_port = [udp, tcp].map { |server| bound_port_of(server) }

      service.shutdown!

      by_protocol = take(stops, 2).to_h { |payload| [payload[:protocol].to_sym, payload[:port]] }
      # A service never calls a transport's own #run!, so each transport must emit its own stop
      # from its own #shutdown! - or a working service reports only the transports that happen to
      # reach that point.
      expect(by_protocol).to eq(udp: udp_port, tcp: tcp_port)
    end
  end

  it 'shutting ONE transport down stops that transport and never the service (GUARD)' do
    with_service do |service, _surface, _starts, _stops|
      udp, tcp = service.servers
      udp_port, tcp_port = [udp, tcp].map { |server| bound_port_of(server) }

      tcp.shutdown!

      # The transport stopped: its listener no longer accepts.
      expect { TCPSocket.new('127.0.0.1', tcp_port).close }.to raise_error(SystemCallError)
      # The service did not: its supervisor was never told to stop and the other transport answers.
      expect(service.cluster.stopping?).to be(false)
      expect(service.worker_pids).to be_nil
      expect(exchange('coap', :udp, udp_port)).to include('Pong')
    end
  end
end
