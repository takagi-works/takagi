# frozen_string_literal: true

require 'json'

# Row 5 of .omo/plans/coap-proxy.md: the forward-proxy form of RFC 7252 5.10.2.
#
# PROOF: nothing on the untouched tree reads Proxy-Uri or Proxy-Scheme; such a request falls through
# to local routing and 4.04. The outbound request is observed ON THE WIRE (the backend echoes the
# option NUMBERS it saw) because Hooks is Scope::LOCAL and the UDP worker forks.
RSpec.describe 'Takagi::Proxy forward-proxy form (plan row 5)' do
  let(:stack) { Takagi::MiddlewareStack.instance }
  let(:codes) { Takagi::CoAP::Registries::Response }

  before do
    @previous_router = stack.router
    @router = Takagi::Router.new
    @router.get('/echo') { |req, _params| { option_numbers: req.options.keys.sort } }
    stack.instance_variable_set(:@router, @router)
  end

  after { stack.instance_variable_set(:@router, @previous_router) }

  def with_backend
    started = Queue.new
    handler = Takagi::Hooks.subscribe(:server_starting) { |payload| started << payload }
    backend = Takagi::Server::Udp.new(port: 0, worker_processes: 1, worker_threads: 1)
    thread = Thread.new { backend.run! }
    Timeout.timeout(5) { started.pop }
    yield backend
  ensure
    Takagi::Hooks.unsubscribe(:server_starting, handler) if handler
    backend&.shutdown!
    thread&.join(5)
  end

  def with_proxy(routes, forward: nil)
    started = Queue.new
    handler = Takagi::Hooks.subscribe(:server_starting) { |payload| started << payload }
    table = Takagi::Proxy::RouteTable.new(routes: routes, forward: forward || :configured)
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

  def ask(port, path, options: {})
    client = Takagi::Client.new("coap://127.0.0.1:#{port}", protocol: :udp, timeout: 8)
    Timeout.timeout(8) { client.get(path, options: options) }
  ensure
    client&.close
  end

  def route_to(backend)
    { prefix: '/backend', host: '127.0.0.1', port: backend.bound_port }
  end

  # A Proxy-Scheme request must reach the proxy while its Uri-Host/Uri-Port name the ORIGIN server,
  # which Takagi::Client cannot express (it derives the Uri-* options from its own target), so this
  # one is built and sent by hand.
  def raw_ask(port, path, options, timeout: 8)
    socket = UDPSocket.new
    socket.bind('127.0.0.1', 0)
    request = Takagi::Message::Request.new(
      method: :get, uri: URI("coap://127.0.0.1:#{port}#{path}"),
      token: SecureRandom.hex(4), options: options
    )
    socket.send(request.to_bytes, 0, '127.0.0.1', port)
    raw, _address = Timeout.timeout(timeout) { socket.recvfrom(2048) }
    Takagi::Client::Response.new(raw, transport: :udp)
  ensure
    socket&.close
  end

  it 'forwards a Proxy-Uri request to the authority it names (PROOF)' do
    with_backend do |backend|
      with_proxy([route_to(backend)]) do |proxy|
        option = "coap://127.0.0.1:#{backend.bound_port}/echo"
        response = ask(proxy.port(:udp), '/', options: { 35 => option })

        expect(response).not_to be_nil
        expect(response.code).to eq(codes::CONTENT)
      end
    end
  end

  it 'forwards a Proxy-Scheme request assembled from the Uri-* options (PROOF)' do
    with_backend do |backend|
      with_proxy([route_to(backend)]) do |proxy|
        options = { 39 => 'coap', 3 => '127.0.0.1', 7 => backend.bound_port }
        response = raw_ask(proxy.port(:udp), '/echo', options)

        expect(response).not_to be_nil
        expect(response.code).to eq(codes::CONTENT)
      end
    end
  end

  it 'refuses Proxy-Uri combined with a Uri-* option instead of forwarding (PROOF)' do
    with_backend do |backend|
      with_proxy([route_to(backend)]) do |proxy|
        option = "coap://127.0.0.1:#{backend.bound_port}/echo"
        response = ask(proxy.port(:udp), '/x', options: { 35 => option })

        expect(response).not_to be_nil
        expect(response.code).to eq(codes::BAD_OPTION)
      end
    end
  end

  it 'consumes the proxy option: the backend sees Uri-Path and no Proxy-Uri/Scheme (PROOF)' do
    with_backend do |backend|
      with_proxy([route_to(backend)]) do |proxy|
        option = "coap://127.0.0.1:#{backend.bound_port}/echo"
        response = ask(proxy.port(:udp), '/', options: { 35 => option })
        seen = JSON.parse(response.payload)['option_numbers']

        expect(seen).to include(11)
        expect(seen).not_to include(35)
        expect(seen).not_to include(39)
      end
    end
  end

  it 'answers 5.05 for a forward-proxy request it will not serve (PROOF)' do
    with_backend do |backend|
      with_proxy([route_to(backend)], forward: :deny) do |proxy|
        option = "coap://127.0.0.1:#{backend.bound_port}/echo"
        response = ask(proxy.port(:udp), '/', options: { 35 => option })

        expect(response).not_to be_nil
        expect(response.code).to eq(codes::PROXYING_NOT_SUPPORTED)
      end
    end
  end

  it 'answers 5.05 when the named authority matches no configured route (PROOF)' do
    with_backend do |backend|
      with_proxy([route_to(backend)]) do |proxy|
        response = ask(proxy.port(:udp), '/', options: { 35 => 'coap://127.0.0.1:1/echo' })

        expect(response).not_to be_nil
        expect(response.code).to eq(codes::PROXYING_NOT_SUPPORTED)
      end
    end
  end
end
