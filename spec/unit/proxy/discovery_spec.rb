# frozen_string_literal: true

require 'socket'
require 'securerandom'

# Row 8 of .omo/plans/coap-proxy.md: `/.well-known/core` at the proxy (RFC 7252 5.7.3, RFC 6690 4).
#
# PROOF: nothing on the untouched tree aggregates anything. Three real backends each answer for
# THEMSELVES; the proxy merges their documents under the route prefixes, drops a backend that does
# not answer, and never caches - the merge happens per request.
RSpec.describe 'Takagi::Proxy discovery aggregation (plan row 8)' do
  let(:stack) { Takagi::MiddlewareStack.instance }
  let(:codes) { Takagi::CoAP::Registries::Response }

  around do |example|
    @router = Takagi::Router.new
    @router.get('/.well-known/core') { "</a>;n=#{SecureRandom.hex(4)},</b>;n=#{SecureRandom.hex(4)}" }
    with_router(@router) { example.run }
  end

  def boot_backends(count)
    started = Queue.new
    handler = Takagi::Hooks.subscribe(:server_starting) { |payload| started << payload }
    backends = Array.new(count) { Takagi::Server::Udp.new(port: 0, worker_processes: 1, worker_threads: 1) }
    threads = backends.map { |backend| Thread.new { backend.run! } }
    count.times { Timeout.timeout(5) { started.pop } }
    yield backends
  ensure
    Takagi::Hooks.unsubscribe(:server_starting, handler) if handler
    backends&.each(&:shutdown!)
    threads&.each { |thread| thread.join(5) }
  end

  def with_proxy(routes, discovery)
    started = Queue.new
    handler = Takagi::Hooks.subscribe(:server_starting) { |payload| started << payload }
    table = Takagi::Proxy::RouteTable.new(routes: routes, discovery: discovery)
    proxy = Takagi::Proxy.new(route_table: table, middleware_stack: stack, router: @router,
                              port: 0, protocols: [:udp])
    thread = Thread.new { proxy.run! }
    Timeout.timeout(5) { started.pop }
    yield proxy
  ensure
    Takagi::Hooks.unsubscribe(:server_starting, handler) if handler
    proxy&.shutdown!
    thread&.join(5)
  end

  def routes_for(backends)
    backends.each_with_index.map do |backend, index|
      { prefix: "/b#{index}", host: '127.0.0.1', port: backend.bound_port }
    end
  end

  def discover(port)
    client = Takagi::Client.new("coap://127.0.0.1:#{port}", protocol: :udp, timeout: 8)
    Timeout.timeout(8) { client.get('/.well-known/core') }
  ensure
    client&.close
  end

  def closed_port
    probe = UDPSocket.new
    probe.bind('127.0.0.1', 0)
    port = probe.addr[1]
    probe.close
    port
  end

  it 'merges every backend under its route prefix with no duplicates (PROOF)' do
    boot_backends(3) do |backends|
      with_proxy(routes_for(backends), :aggregate) do |proxy|
        response = discover(proxy.port(:udp))

        expect(response).not_to be_nil
        expect(response.code).to eq(codes::CONTENT)
        entries = response.payload.split(',')
        expect(response.payload).to include('</b0/a>', '</b1/a>', '</b2/a>')
        expect(response.payload).to include('</b0/b>', '</b1/b>', '</b2/b>')
        expect(entries.uniq).to eq(entries)
      end
    end
  end

  it 'still answers from the reachable backends when one cannot be reached (PROOF)' do
    boot_backends(2) do |backends|
      routes = routes_for(backends) + [{ prefix: '/dead', host: '127.0.0.1', port: closed_port }]
      with_proxy(routes, :aggregate) do |proxy|
        response = discover(proxy.port(:udp))

        expect(response).not_to be_nil
        expect(response.code).to eq(codes::CONTENT)
        expect(response.payload).to include('</b0/a>')
        expect(response.payload).to include('</b1/a>')
        expect(response.payload).not_to include('</dead/a>')
      end
    end
  end

  it 'lists only the proxy own routes when discovery is local (PROOF)' do
    boot_backends(2) do |backends|
      with_proxy(routes_for(backends), :local) do |proxy|
        response = discover(proxy.port(:udp))

        expect(response).not_to be_nil
        expect(response.code).to eq(codes::CONTENT)
        # Read the way the repo reads a discovery document (spec/rfc/rfc_6690_core_link_format_spec.rb:71):
        # one link-format entry per route, each entry the writer's own `<path>;attr` shape.
        entries = response.payload.split(',')
        expect(entries).to eq(['</b0>', '</b1>'])
        expect(entries).to all(match(/\A<[^>]+>(?:;[^,;=]+(?:=(?:"[^"]*"|[^,;]+))?)*\z/))
      end
    end
  end

  it 'sees the backend changing: nothing is cached (PROOF)' do
    boot_backends(1) do |backends|
      with_proxy(routes_for(backends), :aggregate) do |proxy|
        first = discover(proxy.port(:udp))
        second = discover(proxy.port(:udp))

        expect(first.payload).to include('</b0/a>')
        expect(second.payload).not_to eq(first.payload)
      end
    end
  end

  context 'when a backend answers a quoted attribute value containing a comma' do
    # RFC 6690 2: "commas can also occur in quoted strings and URIs but do not end a description".
    around do |example|
      @router = Takagi::Router.new
      @router.get('/.well-known/core') { '</a>;title="a,b",</b>;rt="sensor.x"' }
      with_router(@router) { example.run }
    end

    it 'keeps the quoted value intact with one entry per resource (PROOF)' do
      boot_backends(3) do |backends|
        with_proxy(routes_for(backends), :aggregate) do |proxy|
          response = discover(proxy.port(:udp))

          expect(response).not_to be_nil
          expect(response.code).to eq(codes::CONTENT)

          entries = Takagi::Discovery::CoreLinkFormat.split_entries(response.payload)
          expect(entries.length).to eq(6)
          backends.each_index do |index|
            expect(entries).to include("</b#{index}/a>;title=\"a,b\"", "</b#{index}/b>;rt=\"sensor.x\"")
          end
        end
      end
    end
  end
end
