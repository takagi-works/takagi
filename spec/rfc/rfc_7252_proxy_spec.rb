# frozen_string_literal: true

require 'json'
require 'securerandom'
require 'socket'
require 'timeout'

# Row 12 of .omo/plans/coap-proxy.md: the RFC 7252 proxy conformance spec that row 5's acceptance
# criteria and this plan's verification strategy both name, and which did not exist before it.
#
# Every case runs against REAL sockets: one backend per case and a proxy started the row-10 way -
# direct construction, an injected router, `port: 0`, and every bound port read off the proxy's own
# per-protocol reader (`#port(:udp)` / `#port(:tcp)`) rather than from the configured value or a
# free-port probe. Nothing here is stubbed: a stubbed hop would prove nothing about a proxy, whose
# inbound workers fork and whose `Hooks.emit` is `Scope::LOCAL`, so the outbound hop is only ever
# observable on the wire. Every wait is bounded by `Timeout`, and no example blocks on the clock.
#
# The covered clauses are RFC 7252 5.7 (reverse proxying: the URI path is translated onto the
# backend and the prefix is removed), 5.10.2 (the forward-proxy request form: Proxy-Uri, Proxy-Scheme,
# the Proxy-Uri-plus-Uri-* refusal, and the consumption of the proxy options), 5.7.1/5.7.2 and
# 5.9.3.6 (4.02, 5.02, 5.04, 5.05) and 5.7.2's own-name local-request rule.
RSpec.describe 'Takagi RFC 7252 proxy conformance' do
  let(:stack) { Takagi::MiddlewareStack.instance }
  let(:codes) { Takagi::CoAP::Registries::Response }

  # The stack resolves every route through ITS OWN router (`middleware_stack.rb#call`), so the router
  # handed to the proxy and to the backends is only the one that serves while the stack points at it
  # too; it is restored afterwards so the suite's global router is never left pointed elsewhere.
  around do |example|
    @router = Takagi::Router.new
    # The backend reports what the proxy actually placed on the wire: the path it received (the
    # prefix must be gone) and the option NUMBERS it saw (the proxy options must be gone).
    @router.get('/echo') { |req, _params| { path: req.uri.path, option_numbers: req.options.keys.sort } }
    @router.get('/payload') { { message: 'the backend payload' } }
    @router.get('/local') { { message: 'the proxy answered locally' } }
    with_router(@router) { example.run }
  end

  # A real backend on its own bound port, waited for on the `:server_starting` payload the repo's
  # direct-construction specs use. `klass` is `Server::Udp` or `Server::Tcp`.
  def with_backend(klass = Takagi::Server::Udp)
    started = Queue.new
    handler = Takagi::Hooks.subscribe(:server_starting) { |payload| started << payload }
    backend = klass.new(port: 0, router: @router, middleware_stack: stack,
                        worker_processes: 1, worker_threads: 1)
    thread = Thread.new { backend.run! }
    Timeout.timeout(10) { started.pop }
    yield backend
  ensure
    Takagi::Hooks.unsubscribe(:server_starting, handler) if handler
    backend&.shutdown!
    thread&.join(10)
  end

  # The proxy, started the row-10 way. One `:server_starting` payload per listener is the boot
  # signal, and the ports come from the proxy's own reader.
  def with_proxy(routes, forward: :configured, names: [], protocols: %i[udp tcp])
    started = Queue.new
    handler = Takagi::Hooks.subscribe(:server_starting) { |payload| started << payload }
    table = Takagi::Proxy::RouteTable.new(routes: routes, names: names, forward: forward)
    proxy = Takagi::Proxy.new(route_table: table, middleware_stack: stack, router: @router,
                              port: 0, protocols: protocols)
    thread = Thread.new { proxy.run! }
    Array.new(Array(protocols).size) { Timeout.timeout(10) { started.pop } }
    yield proxy
  ensure
    Takagi::Hooks.unsubscribe(:server_starting, handler) if handler
    proxy&.shutdown!
    thread&.join(10)
  end

  # One bounded exchange through a real client; the client's own timeout is the first bound and the
  # enclosing `Timeout` is the backstop.
  def ask(protocol, port, path, options: {}, timeout: 10)
    scheme = protocol == :tcp ? 'coap+tcp' : 'coap'
    client = Takagi::Client.new("#{scheme}://127.0.0.1:#{port}", protocol: protocol, timeout: timeout)
    Timeout.timeout(timeout + 2) { client.get(path, options: options) }
  ensure
    client&.close
  end

  # The Proxy-Scheme form carries Uri-Host/Uri-Port, which `Takagi::Client` derives from its OWN
  # target and therefore cannot express; this one is encoded and sent by hand.
  def raw_ask(port, path, options, timeout: 10)
    socket = UDPSocket.new
    socket.bind('127.0.0.1', 0)
    request = Takagi::Message::Request.new(
      method: :get, uri: URI("coap://127.0.0.1:#{port}#{path}"),
      token: SecureRandom.hex(4), options: options
    )
    socket.send(request.to_bytes, 0, '127.0.0.1', port)
    raw, _address = Timeout.timeout(timeout) { socket.recvfrom(4096) }
    Takagi::Client::Response.new(raw, transport: :udp)
  ensure
    socket&.close
  end

  def route_to(backend, prefix: '/backend')
    { prefix: prefix, host: '127.0.0.1', port: backend.bound_port }
  end

  it 'forwards a prefix-route request to the backend that owns the path, over UDP (5.7)' do
    with_backend do |backend|
      with_proxy([route_to(backend)]) do |proxy|
        response = ask(:udp, proxy.port(:udp), '/backend/echo')

        expect(response).not_to be_nil
        expect(response.code).to eq(codes::CONTENT)
        # The prefix is the proxy's namespace and was removed: the backend was addressed at /echo.
        expect(JSON.parse(response.payload)['path']).to eq('/echo')
      end
    end
  end

  it 'forwards a prefix-route request over its TCP listener, reading the TCP port (5.7)' do
    with_backend(Takagi::Server::Tcp) do |backend|
      with_proxy([route_to(backend)]) do |proxy|
        response = ask(:tcp, proxy.port(:tcp), '/backend/payload')

        expect(response).not_to be_nil
        expect(response.code).to eq(codes::CONTENT)
        expect(response.payload).to include('the backend payload')
      end
    end
  end

  it 'forwards a Proxy-Uri request to the authority it names (5.10.2)' do
    with_backend do |backend|
      with_proxy([route_to(backend)]) do |proxy|
        option = "coap://127.0.0.1:#{backend.bound_port}/payload"
        response = ask(:udp, proxy.port(:udp), '/', options: { 35 => option })

        expect(response).not_to be_nil
        expect(response.code).to eq(codes::CONTENT)
        expect(response.payload).to include('the backend payload')
      end
    end
  end

  it 'forwards a Proxy-Scheme request assembled from the Uri-* options (5.10.2)' do
    with_backend do |backend|
      with_proxy([route_to(backend)]) do |proxy|
        options = { 39 => 'coap', 3 => '127.0.0.1', 7 => backend.bound_port }
        response = raw_ask(proxy.port(:udp), '/payload', options)

        expect(response).not_to be_nil
        expect(response.code).to eq(codes::CONTENT)
        expect(response.payload).to include('the backend payload')
      end
    end
  end

  it 'refuses Proxy-Uri combined with a Uri-* option instead of resolving it (5.10.2)' do
    with_backend do |backend|
      with_proxy([route_to(backend)]) do |proxy|
        option = "coap://127.0.0.1:#{backend.bound_port}/payload"
        # The client's own path becomes a Uri-Path option, which 5.10.2 forbids beside Proxy-Uri.
        response = ask(:udp, proxy.port(:udp), '/payload', options: { 35 => option })

        expect(response).not_to be_nil
        expect(response.code).to eq(codes::BAD_OPTION)
      end
    end
  end

  it 'consumes the proxy option: the backend sees Uri-Path and no Proxy-Uri/Proxy-Scheme (5.7.2)' do
    with_backend do |backend|
      with_proxy([route_to(backend)]) do |proxy|
        option = "coap://127.0.0.1:#{backend.bound_port}/echo"
        response = ask(:udp, proxy.port(:udp), '/', options: { 35 => option })
        seen = JSON.parse(response.payload)['option_numbers']

        expect(seen).to include(11)          # Uri-Path: the target the Proxy-Uri was split into
        expect(seen).not_to include(35, 39)  # Proxy-Uri/Proxy-Scheme are the proxy's own
      end
    end
  end

  it 'refuses an unrecognized UNSAFE request option with 4.02 (5.7.1)' do
    with_backend do |backend|
      with_proxy([route_to(backend)]) do |proxy|
        # Option 66 is elective AND unsafe: a proxy keys on Unsafe/Safe-to-Forward, not on Critical.
        response = ask(:udp, proxy.port(:udp), '/backend/echo', options: { 66 => 'x' })

        expect(response).not_to be_nil
        expect(response.code).to eq(codes::BAD_OPTION)
      end
    end
  end

  it 'answers 5.02 when the backend answer cannot be parsed (5.7.2)' do
    answerer_socket = UDPSocket.new
    answerer_socket.bind('127.0.0.1', 0)
    answerer = Thread.new do
      loop do
        _data, addr = answerer_socket.recvfrom(2048)
        answerer_socket.send("\x00\x01garbage".b, 0, addr[3], addr[1])
      end
    rescue IOError, Errno::EBADF
      nil
    end

    with_proxy([{ prefix: '/backend', host: '127.0.0.1', port: answerer_socket.addr[1] }]) do |proxy|
      response = ask(:udp, proxy.port(:udp), '/backend/echo')

      expect(response).not_to be_nil
      expect(response.code).to eq(codes::BAD_GATEWAY)
    end
  ensure
    answerer&.kill
    answerer_socket&.close
  end

  it 'answers 5.04 when the backend never answers (5.7.2)' do
    probe = UDPSocket.new
    probe.bind('127.0.0.1', 0)
    dead_port = probe.addr[1]
    probe.close

    with_proxy([{ prefix: '/backend', host: '127.0.0.1', port: dead_port }]) do |proxy|
      response = ask(:udp, proxy.port(:udp), '/backend/echo')

      expect(response).not_to be_nil
      expect(response.code).to eq(codes::GATEWAY_TIMEOUT)
    end
  end

  it 'answers 5.05 when it will not forward-proxy to the named authority (5.9.3.6)' do
    with_backend do |backend|
      with_proxy([route_to(backend)], forward: :deny) do |proxy|
        option = "coap://127.0.0.1:#{backend.bound_port}/payload"
        response = ask(:udp, proxy.port(:udp), '/', options: { 35 => option })

        expect(response).not_to be_nil
        expect(response.code).to eq(codes::PROXYING_NOT_SUPPORTED)
      end
    end
  end

  it 'answers a request naming the proxy own authority locally, never forwarding it (5.7.2, 5.10.2)' do
    # No route claims the proxy's own authority, so 5.05 - not a local 2.05 - is what a proxy
    # without 5.7.2's own-name rule would answer; the local route is what proves the rule fired.
    with_proxy([], names: ['127.0.0.1']) do |proxy|
      option = "coap://127.0.0.1:#{proxy.port(:udp)}/local"
      response = ask(:udp, proxy.port(:udp), '/', options: { 35 => option })

      expect(response).not_to be_nil
      expect(response.code).to eq(codes::CONTENT)
      expect(response.payload).to include('the proxy answered locally')
    end
  end
end
