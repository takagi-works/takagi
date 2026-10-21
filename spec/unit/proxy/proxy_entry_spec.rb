# frozen_string_literal: true

# Row 10 of .omo/plans/coap-proxy.md: the proxy's entry point, which rows 2-9 all start a proxy
# through.
#
# PROOF: `Takagi::Proxy` does not exist on the untouched tree, so every example here fails before
# this row. The listeners are ordinary `Server::Udp`/`Server::Tcp` instances constructed with an
# injected router, and their ports are read PER PROTOCOL because `port: 0` gives each listener its
# own ephemeral port.
RSpec.describe 'Takagi::Proxy (plan row 10 entry point)' do
  # Row 1 owns the route table; this row's entry point only HOLDS it, so a stand-in object proves
  # the constructor wiring. It answers `resolve` with nil (row 2's forwarding path is what resolves
  # through it), which keeps this row independent of row 1 and makes every request answer locally.
  let(:route_table) { double('route table', resolve: nil, register_own_ports: nil) }
  let(:stack) { Takagi::MiddlewareStack.instance }

  # The middleware stack resolves every route through ITS OWN router at call time
  # (`middleware_stack.rb:75`), so a router handed to the proxy is the one that serves only while
  # the stack points at it too. The throwaway router is installed for the example through the
  # shared `with_router` helper (row 23), whose `ensure` restores the suite's global router.
  around do |example|
    @router = Takagi::Router.new
    @router.get('/proxy/probe') { { message: 'answered locally' } }
    with_router(@router) { example.run }
  end

  def exchange(protocol, port, path, timeout: 5)
    queue = Queue.new
    client = Takagi::Client.new("coap://127.0.0.1:#{port}", protocol: protocol, timeout: timeout)
    client.get(path) { |response| queue << response }
    Timeout.timeout(timeout) { queue.pop }.payload
  ensure
    client&.close
  end

  # Boots a proxy on its ephemeral ports and waits for one `:server_starting` payload per
  # listener - the boot signal the repo's own direct-construction specs wait on - before yielding.
  # Nothing here sleeps: the sockets are already bound and listening when the proxy is constructed.
  def with_proxy(protocols: %i[udp tcp], **options)
    started = Queue.new
    handler = Takagi::Hooks.subscribe(:server_starting) { |payload| started << payload }
    proxy = Takagi::Proxy.new(route_table: route_table, middleware_stack: stack, router: @router,
                              port: 0, protocols: protocols, **options)
    thread = Thread.new { proxy.run! }
    Array.new(Array(protocols).size) { Timeout.timeout(5) { started.pop } }
    yield proxy
  ensure
    Takagi::Hooks.unsubscribe(:server_starting, handler) if handler
    proxy&.shutdown!
    thread&.join(5)
  end

  it 'constructs one listener per protocol with the injected router, reports own bound ports (PROOF)' do
    with_proxy do |proxy|
      expect(proxy.route_table).to be(route_table)
      expect(proxy.router).to be(@router)
      expect(proxy.servers.map(&:class)).to eq([Takagi::Server::Udp, Takagi::Server::Tcp])

      expect(proxy.ports.keys).to eq(%i[udp tcp])
      expect(proxy.port(:udp)).to be_positive
      expect(proxy.port(:tcp)).to be_positive
      expect(proxy.port(:udp)).not_to eq(proxy.port(:tcp))
      expect(proxy.port(:udp)).to eq(bound_port_of(proxy.servers[0]))
      expect(proxy.port(:tcp)).to eq(bound_port_of(proxy.servers[1]))
    end
  end

  it 'performs an exchange through the UDP listener (PROOF)' do
    with_proxy do |proxy|
      expect(exchange(:udp, proxy.port(:udp), '/proxy/probe')).to include('answered locally')
    end
  end

  it 'performs an exchange through the TCP listener (PROOF)' do
    with_proxy do |proxy|
      expect(exchange(:tcp, proxy.port(:tcp), '/proxy/probe')).to include('answered locally')
    end
  end

  it 'serves one protocol only when the proxy is constructed with one (PROOF)' do
    with_proxy(protocols: [:udp]) do |proxy|
      expect(proxy.ports.keys).to eq([:udp])
      expect { proxy.port(:tcp) }.to raise_error(ArgumentError, /listens for \[:udp\], not :tcp/)
    end
  end
end
