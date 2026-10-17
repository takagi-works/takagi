# frozen_string_literal: true

require 'stringio'

# Row 6 of .omo/plans/unified-cluster.md: ONE boot surface per service. A service exposing udp
# AND tcp on `port: 0` gets two kernel-assigned ports, and nothing reported either honestly:
# `build_servers` resolved one `port:` for every protocol and UDP's own `:server_starting`
# payload carries the REQUESTED port (0) - row 2's recorded open item, IS-7. The surface
# asserted here is the service-level one, emitted once per service where the servers are built
# (the `:service_starting` hook payload and the boot-log line). The transports' own
# `:server_starting` payloads stay untouched, key for key - that is the GUARD.
RSpec.describe 'the service boot surface (plan row 6)' do
  # Boots a service through the public API with the ONE boot surface armed BEFORE it boots, so
  # no event can be missed, and returns [service, surface payload, boot log].
  def boot_service(protocols: %i[udp tcp])
    payloads = Queue.new
    handler = Takagi::Hooks.subscribe(:service_starting) { |payload| payloads << payload }
    log = StringIO.new
    original = $stdout
    $stdout = log
    service = begin
      Takagi::Base.spawn!(port: 0, protocols: protocols)
    ensure
      $stdout = original
    end
    surface = begin
      Timeout.timeout(5) { payloads.pop }
    rescue Timeout::Error
      raise 'no :service_starting payload arrived within 5s: the service boot surface is missing'
    end
    [service, surface, log.string]
  ensure
    Takagi::Hooks.unsubscribe(:service_starting, handler)
  end

  def capture_transport_boot(protocols)
    queue = Queue.new
    handler = Takagi::Hooks.subscribe(:server_starting) { |payload| queue << payload }
    server = Takagi::Base.spawn!(port: 0, protocols: protocols)
    [server, Timeout.timeout(5) { queue.pop }]
  ensure
    Takagi::Hooks.unsubscribe(:server_starting, handler)
  end

  # A real CoAP exchange through the public client, over the given scheme and transport.
  def exchange(scheme, protocol, port)
    client = Takagi::Client.new("#{scheme}://127.0.0.1:#{port}", protocol: protocol, timeout: 10)
    responses = Queue.new
    client.get('/ping') { |response| responses << response }
    Timeout.timeout(10) { responses.pop }.payload
  ensure
    client&.close
  end

  def servers_of(service)
    service.instance_variable_get(:@servers)
  end

  it 'reports the transport set, the worker count and EACH bound port in ONE payload (PROOF)' do
    service, surface, log = boot_service
    udp_server, tcp_server = servers_of(service)
    udp_port, tcp_port = [udp_server, tcp_server].map { |server| bound_port_of(server) }

    expect(surface[:protocols]).to eq(%i[udp tcp])
    expect(surface[:processes]).to eq(1)
    expect(surface[:ports].keys).to contain_exactly(:udp, :tcp)
    expect(surface[:ports][:udp]).to eq(udp_port)
    expect(surface[:ports][:tcp]).to eq(tcp_port)
    expect(surface[:ports].values).to all(be_positive)

    expect(log).to include('protocols=udp,tcp')
    expect(log).to include('processes=1')
    expect(log).to include("udp:#{udp_port}")
    expect(log).to include("tcp:#{tcp_port}")
  ensure
    service&.shutdown!
  end

  it 'keeps the shipped :server_starting keys and their meaning for a TCP-only service (GUARD)' do
    server, payload = capture_transport_boot([:tcp])

    expect(payload.keys.map(&:to_sym).sort).to eq(%i[port protocol])
    expect(payload[:protocol]).to eq(:tcp)
    expect(payload[:port]).to eq(bound_port_of(server))
  ensure
    server&.shutdown!
  end

  it 'keeps the shipped :server_starting keys for a UDP-only service (GUARD)' do
    server, payload = capture_transport_boot([:udp])

    expect(payload.keys.map(&:to_sym).sort).to eq(%i[port protocol])
    expect(payload[:protocol]).to eq(:udp)
  ensure
    server&.shutdown!
  end

  it 'serves BOTH transports from ONE process at count 1, and says so with its own pid (PROOF 2)' do
    service, surface, log = boot_service
    servers = servers_of(service)

    # The count-1 service forked nothing, so the process answering both exchanges IS this one:
    # `waitpid WNOHANG` raises ECHILD when no child exists at all, while `kill(0)` would succeed
    # on a zombie and could not tell the two apart.
    expect { Process.waitpid(-1, Process::WNOHANG) }.to raise_error(Errno::ECHILD)
    expect(servers.map(&:worker_pids)).to eq([nil, nil])
    expect(service.worker_pids).to be_nil

    udp_port, tcp_port = servers.map { |server| bound_port_of(server) }
    expect(exchange('coap', :udp, udp_port)).to include('Pong')
    expect(exchange('coap+tcp', :tcp, tcp_port)).to include('Pong')

    expect(surface[:processes]).to eq(1)
    expect(surface[:pid]).to eq(Process.pid)
    expect(log).to include("pid=#{Process.pid}")
  ensure
    service&.shutdown!
  end
end
