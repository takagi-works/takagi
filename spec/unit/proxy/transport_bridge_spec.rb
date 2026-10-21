# frozen_string_literal: true

require 'socket'

# Row 4 of .omo/plans/coap-proxy.md: a route may switch the transport the proxy forwards on.
#
# PROOF: on the untouched tree there is no forwarding path at all, let alone a cross-transport one.
# The outbound hop is observed ON THE WIRE - `Hooks.emit` is `Scope::LOCAL` and the UDP worker forks,
# so a spec cannot read the proxy's own events - by having the backend echo the identity it saw.
# Reliability and assembly are PER HOP (RFC 8323 1); the device only ever speaks its own transport.
RSpec.describe 'Takagi::Proxy transport bridging (plan row 4)' do
  let(:stack) { Takagi::MiddlewareStack.instance }
  let(:codes) { Takagi::CoAP::Registries::Response }

  around do |example|
    @router = Takagi::Router.new
    @router.get('/echo') do |req, _params|
      { seen_token: req.token.unpack1('H*'), seen_mid: req.message_id }
    end
    with_router(@router) { example.run }
  end

  def with_server(klass)
    started = Queue.new
    handler = Takagi::Hooks.subscribe(:server_starting) { |payload| started << payload }
    server = klass.new(port: 0, worker_processes: 1, worker_threads: 1)
    thread = Thread.new { server.run! }
    Timeout.timeout(5) { started.pop }
    yield server
  ensure
    Takagi::Hooks.unsubscribe(:server_starting, handler) if handler
    server&.shutdown!
    thread&.join(5)
  end

  def with_proxy(routes, protocols)
    started = Queue.new
    handler = Takagi::Hooks.subscribe(:server_starting) { |payload| started << payload }
    table = Takagi::Proxy::RouteTable.new(routes: routes)
    proxy = Takagi::Proxy.new(route_table: table, middleware_stack: stack, router: @router,
                              port: 0, protocols: protocols)
    thread = Thread.new { proxy.run! }
    Timeout.timeout(5) { started.pop }
    yield proxy
  ensure
    Takagi::Hooks.unsubscribe(:server_starting, handler) if handler
    proxy&.shutdown!
    thread&.join(5)
  end

  def ask(scheme, protocol, port, path)
    client = Takagi::Client.new("#{scheme}://127.0.0.1:#{port}", protocol: protocol, timeout: 8)
    Timeout.timeout(8) { client.get(path) }
  ensure
    client&.close
  end

  it 'carries a UDP client to a TCP backend and back on UDP (PROOF)' do
    with_server(Takagi::Server::Tcp) do |backend|
      route = { prefix: '/backend', host: '127.0.0.1', port: backend.bound_port, outbound: :tcp }
      with_proxy([route], [:udp]) do |proxy|
        response = ask('coap', :udp, proxy.port(:udp), '/backend/echo')

        expect(response).not_to be_nil
        expect(response.code).to eq(codes::CONTENT)
        echo = JSON.parse(response.payload)
        expect(echo['seen_token']).to be_a(String)
      end
    end
  end

  it 'carries a TCP client to a UDP backend and back on TCP (PROOF)' do
    with_server(Takagi::Server::Udp) do |backend|
      route = { prefix: '/backend', host: '127.0.0.1', port: backend.bound_port, outbound: :udp }
      with_proxy([route], [:tcp]) do |proxy|
        response = ask('coap+tcp', :tcp, proxy.port(:tcp), '/backend/echo')

        expect(response).not_to be_nil
        expect(response.code).to eq(codes::CONTENT)
        echo = JSON.parse(response.payload)
        expect(echo['seen_token']).to be_a(String)
      end
    end
  end

  it 're-originates the identity on the TCP hop: no Message ID and a fresh token (PROOF)' do
    with_server(Takagi::Server::Tcp) do |backend|
      route = { prefix: '/backend', host: '127.0.0.1', port: backend.bound_port, outbound: :tcp }
      with_proxy([route], [:udp]) do |proxy|
        response = ask('coap', :udp, proxy.port(:udp), '/backend/echo')
        echo = JSON.parse(response.payload)

        # CoAP over TCP (RFC 8323) has no Message ID, and the token is the outbound hop's own.
        expect(echo['seen_mid']).to be_nil
        expect(echo['seen_token']).not_to eq(response.token.unpack1('H*'))
      end
    end
  end

  it 'answers a bounded failure when a TCP backend closes on it (PROOF)' do
    listener = TCPServer.new('127.0.0.1', 0)
    port = listener.addr[1]
    closer = Thread.new do
      loop do
        socket = listener.accept
        socket.close
      end
    rescue IOError, Errno::EBADF
      nil
    end

    route = { prefix: '/dead', host: '127.0.0.1', port: port, outbound: :tcp }
    with_proxy([route], [:udp]) do |proxy|
      response = ask('coap', :udp, proxy.port(:udp), '/dead/x')

      expect(response).not_to be_nil
      expect(response.code).to eq(codes::GATEWAY_TIMEOUT)
    end
  ensure
    closer&.kill
    listener&.close
  end
end
