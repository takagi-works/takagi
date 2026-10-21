# frozen_string_literal: true

require 'json'

# Row 5 of .omo/plans/coap-proxy.md: the forward-proxy form of RFC 7252 5.10.2.
#
# PROOF: nothing on the untouched tree reads Proxy-Uri or Proxy-Scheme; such a request falls through
# to local routing and 4.04. The outbound request is observed ON THE WIRE (the backend echoes the
# option NUMBERS it saw plus the Uri-Host/Uri-Port it decoded) because Hooks is Scope::LOCAL and the
# UDP worker forks.
RSpec.describe 'Takagi::Proxy forward-proxy form (plan row 5)' do
  let(:stack) { Takagi::MiddlewareStack.instance }
  let(:codes) { Takagi::CoAP::Registries::Response }

  around do |example|
    @router = Takagi::Router.new
    @router.get('/echo') do |req, _params|
      { option_numbers: req.options.keys.sort,
        uri_host: Array(req.options[3]).first,
        uri_port: decode_option_uint(req.options[7]) }
    end
    with_router(@router) { example.run }
  end

  def decode_option_uint(raw)
    bytes = Array(raw).first.to_s.b
    return 0 if bytes.empty?

    bytes.bytes.reduce(0) { |acc, byte| (acc << 8) | byte }
  end

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

  # RFC 7252 5.7.2: a proxy request's URI "is decoded and split into the Uri-Host, Uri-Port,
  # Uri-Path and Uri-Query Options", and the Proxy-Uri/Proxy-Scheme option is consumed rather than
  # forwarded. Both forms of a proxy request must therefore reach the backend as that ordinary
  # origin-server request, carrying the authority the client named.
  shared_examples 'a request forwarded to the target authority' do
    it 'carries Uri-Host/Uri-Port/Uri-Path and no Proxy-Uri/Proxy-Scheme (PROOF)' do
      with_backend do |backend|
        with_proxy([route_to(backend)]) do |proxy|
          response = send_targeted(proxy.port(:udp), backend)

          expect(response).not_to be_nil
          expect(response.code).to eq(codes::CONTENT)

          echo = JSON.parse(response.payload)
          expect(echo['option_numbers']).to include(3, 7, 11)
          expect(echo['option_numbers']).not_to include(35, 39)
          expect(echo['uri_host']).to eq('127.0.0.1')
          expect(echo['uri_port']).to eq(backend.bound_port)
        end
      end
    end
  end

  context 'with a Proxy-Uri target' do
    def send_targeted(port, backend)
      ask(port, '/', options: { 35 => "coap://127.0.0.1:#{backend.bound_port}/echo" })
    end

    it_behaves_like 'a request forwarded to the target authority'
  end

  context 'with a Proxy-Scheme target' do
    def send_targeted(port, backend)
      raw_ask(port, '/echo', { 39 => 'coap', 3 => '127.0.0.1', 7 => backend.bound_port })
    end

    it_behaves_like 'a request forwarded to the target authority'
  end

  # The other half of the rule: a prefix route's destination is the route's own authority, not a URI
  # the client named, so no Uri-Host/Uri-Port is written for that hop (RFC 7252 5.7.3).
  it 'leaves Uri-Host and Uri-Port off a prefix-route hop (GUARD)' do
    with_backend do |backend|
      with_proxy([route_to(backend)]) do |proxy|
        response = ask(proxy.port(:udp), '/backend/echo')

        expect(response.code).to eq(codes::CONTENT)
        expect(JSON.parse(response.payload)['option_numbers']).not_to include(3, 7)
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

  # Row 24. RFC 7252 5.7.2: "the scheme of the request URI defines the outgoing protocol and its
  # details", and an endpoint "unable or unwilling to act as proxy for the request URI" MUST return
  # 5.05 (5.7.2, 5.10.2, 5.9.3.6). Until this row every scheme but "coap+tcp" was mapped to UDP, so
  # the same request named `http://` reached the backend and drew 2.05 - the assertion below is the
  # discriminator for that change, and the authority IS one of the configured routes either way.
  it 'refuses a Proxy-Uri naming a scheme it cannot serve instead of forwarding it over UDP (PROOF)' do
    with_backend do |backend|
      with_proxy([route_to(backend)]) do |proxy|
        response = ask(proxy.port(:udp), '/',
                       options: { 35 => "http://127.0.0.1:#{backend.bound_port}/echo" })

        expect(response).not_to be_nil
        expect(response.code).to eq(codes::PROXYING_NOT_SUPPORTED)
      end
    end
  end

  # Follow-up to row 11. RFC 7252 6.1 adopts IP-literal from RFC 3986, whose production is
  # "[" ( IPv6address / IPvFuture ) "]" - the brackets ARE part of it - and 6.5 step 2 fails any
  # host that is not a valid reg-name, IP-literal or IPv4address. An IPv6 target must therefore
  # carry the BRACKETED literal in its Uri-Host Option, which is what `Forwarder#bracketed_host`
  # writes; it previously wrote the proxy's canonical UNBRACKETED form, which no strict receiver
  # composing a URI from the options could accept.
  #
  # The hop itself cannot be PLACED on an IPv6 peer today: the transmit path resolves through an
  # AF_INET socket and dies with `getaddrinfo: No address associated with hostname`, which is a
  # general client limitation, not this proxy's. So this asserts the Option the proxy BUILDS - the
  # layer this fix changes - and the control below keeps the bracketing rule honest.
  describe 'the Uri-Host Option an IPv6 target produces' do
    let(:forwarder) { Takagi::Proxy::Forwarder.new(logger: Logger.new(IO::NULL)) }
    let(:uri_host) { Takagi::CoAP::Registries::Option::URI_HOST }

    def options_for(uri_text)
      target = Takagi::Proxy::ForwardTarget.for(nil, uri_text, nil)
      forwarder.send(:forwarded_options, Struct.new(:options).new({}), target)
    end

    it 'brackets an IPv6 literal (RFC 7252 6.1 + 6.5 step 2)' do
      expect(options_for('coap://[2001:db8::2:1]:5683/x')[uri_host]).to eq('[2001:db8::2:1]')
      expect(options_for('coap://[::1]:5683/x')[uri_host]).to eq('[::1]')
    end

    it 'leaves an IPv4 literal and a reg-name exactly as they were' do
      expect(options_for('coap://192.0.2.1:5683/x')[uri_host]).to eq('192.0.2.1')
      expect(options_for('coap://example.net:5683/x')[uri_host]).to eq('example.net')
    end

    it 'still brackets the outbound endpoint URI exactly once' do
      expect(forwarder.send(:endpoint_for, '2001:db8::2:1', 5683, :udp))
        .to eq('coap://[2001:db8::2:1]:5683')
      expect(forwarder.send(:endpoint_for, '192.0.2.1', 5683, :udp))
        .to eq('coap://192.0.2.1:5683')
    end
  end
end
