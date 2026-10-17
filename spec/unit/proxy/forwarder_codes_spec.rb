# frozen_string_literal: true

require 'socket'

# Row 3 of .omo/plans/coap-proxy.md: the four normative answers a proxy owes when it cannot simply
# pass a request through (RFC 7252 5.7.1/5.7.2/5.9.3.6).
#
# PROOF: none of these codes is emitted for a PROXY case on the untouched tree, and the
# Unsafe/Safe-to-Forward predicates have no proxy caller. The deciding class for a REQUEST option is
# Unsafe, NOT Critical: option 66 is elective and unsafe (4.02), option 68 is elective and safe, and
# option 69 is critical and safe - the last two are forwarded (RFC 7252 5.4.1: the Critical rules
# apply to NON-proxying endpoints). The backend echoes what it sees ON THE WIRE.
RSpec.describe 'Takagi::Proxy refusal and failure codes (plan row 3)' do
  let(:stack) { Takagi::MiddlewareStack.instance }
  let(:codes) { Takagi::CoAP::Registries::Response }

  before do
    @previous_router = stack.router
    @router = Takagi::Router.new
    @router.get('/echo') { |req, _params| { seen_token: req.token.unpack1('H*') } }
    @router.get('/unsafe-answer') do |req, _params|
      Takagi::Message::Outbound.new(code: codes::CONTENT, payload: 'unsafe', token: req.token,
                                    message_id: req.message_id, options: { 66 => 'bad' })
    end
    @router.get('/safe-answer') do |req, _params|
      Takagi::Message::Outbound.new(code: codes::CONTENT, payload: 'safe', token: req.token,
                                    message_id: req.message_id, options: { 68 => 'ok' })
    end
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

  def with_proxy(routes)
    started = Queue.new
    handler = Takagi::Hooks.subscribe(:server_starting) { |payload| started << payload }
    table = Takagi::Proxy::RouteTable.new(routes: routes)
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

  def ask(port, path, options: {}, timeout: 10)
    client = Takagi::Client.new("coap://127.0.0.1:#{port}", protocol: :udp, timeout: timeout)
    Timeout.timeout(timeout) { client.get(path, options: options) }
  ensure
    client&.close
  end

  def route_for(prefix, port)
    { prefix: prefix, host: '127.0.0.1', port: port }
  end

  it 'refuses an unrecognized UNSAFE option with 4.02, keyed on the unsafe bit (PROOF)' do
    with_backend do |backend|
      with_proxy([route_for('/backend', backend.bound_port)]) do |proxy|
        response = ask(proxy.port(:udp), '/backend/echo', options: { 66 => 'x' })

        expect(response).not_to be_nil
        expect(response.code).to eq(codes::BAD_OPTION)
      end
    end
  end

  it 'forwards an unrecognized SAFE option whether elective (68) or critical (69) (PROOF)' do
    with_backend do |backend|
      with_proxy([route_for('/backend', backend.bound_port)]) do |proxy|
        [68, 69].each do |number|
          response = ask(proxy.port(:udp), '/backend/echo', options: { number => 'x' })
          expect(response).not_to be_nil
          expect(response.code).to eq(codes::CONTENT),
                                   "option #{number} should be forwarded, got #{response.code_name}"
        end
      end
    end
  end

  it 'answers 5.04 when the backend never replies (PROOF)' do
    probe = UDPSocket.new
    probe.bind('127.0.0.1', 0)
    dead_port = probe.addr[1]
    probe.close

    with_proxy([route_for('/dead', dead_port)]) do |proxy|
      response = ask(proxy.port(:udp), '/dead/x')

      expect(response).not_to be_nil
      expect(response.code).to eq(codes::GATEWAY_TIMEOUT)
    end
  end

  it 'answers 5.02 when the backend answers with bytes it cannot parse (PROOF)' do
    server = UDPSocket.new
    server.bind('127.0.0.1', 0)
    port = server.addr[1]
    thread = Thread.new do
      loop do
        _data, addr = server.recvfrom(2048)
        server.send("\x00\x01garbage".b, 0, addr[3], addr[1])
      end
    end

    with_proxy([route_for('/garbage', port)]) do |proxy|
      response = ask(proxy.port(:udp), '/garbage/x')

      expect(response).not_to be_nil
      expect(response.code).to eq(codes::BAD_GATEWAY)
    end
  ensure
    thread&.kill
    server&.close
  end

  it 'answers 5.02 when the backend response carries an unrecognized UNSAFE option (PROOF)' do
    with_backend do |backend|
      with_proxy([route_for('/backend', backend.bound_port)]) do |proxy|
        response = ask(proxy.port(:udp), '/backend/unsafe-answer')

        expect(response).not_to be_nil
        expect(response.code).to eq(codes::BAD_GATEWAY)
      end
    end
  end

  it 'forwards a backend response carrying an unrecognized SAFE option untouched (PROOF)' do
    with_backend do |backend|
      with_proxy([route_for('/backend', backend.bound_port)]) do |proxy|
        response = ask(proxy.port(:udp), '/backend/safe-answer')

        expect(response).not_to be_nil
        expect(response.code).to eq(codes::CONTENT)
        expect(response.payload).to include('safe')
      end
    end
  end
end
