# frozen_string_literal: true

require 'socket'

# Row 6 of .omo/plans/coap-proxy.md: a request naming the proxy itself is answered LOCALLY, never
# forwarded (RFC 7252 5.7.2 and 5.10.2's own-name MUST) - the mechanism that makes a request loop
# impossible without a hop counter or a non-standard header.
#
# PROOF: no code on the untouched tree recognizes its own authority, and there is no proxy at all.
# The local answer is observed ON THE WIRE (the payload comes from the proxy's own route).
RSpec.describe 'Takagi::Proxy loop safety (plan row 6)' do
  let(:stack) { Takagi::MiddlewareStack.instance }
  let(:codes) { Takagi::CoAP::Registries::Response }

  before do
    @previous_router = stack.router
    @router = Takagi::Router.new
    @router.get('/local') { { message: 'answered by the proxy itself' } }
    @router.get('/echo') { { message: 'backend answered' } }
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

  def with_proxy(routes, names:)
    started = Queue.new
    handler = Takagi::Hooks.subscribe(:server_starting) { |payload| started << payload }
    table = Takagi::Proxy::RouteTable.new(routes: routes, names: names, forward: :configured)
    proxy = Takagi::Proxy.new(route_table: table, middleware_stack: stack, router: @router,
                              port: 0, protocols: [:udp])
    thread = Thread.new { proxy.run! }
    Timeout.timeout(5) { started.pop }
    yield proxy, table
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

  it 'answers a request naming one of the proxy own names locally (PROOF)' do
    with_backend do |backend|
      with_proxy([route_to(backend)], names: ['127.0.0.1']) do |proxy, table|
        expect(table.own_authority?('127.0.0.1', proxy.port(:udp))).to be(true)

        option = "coap://127.0.0.1:#{proxy.port(:udp)}/local"
        response = ask(proxy.port(:udp), '/', options: { 35 => option })

        expect(response).not_to be_nil
        expect(response.payload).to include('answered by the proxy itself')
      end
    end
  end

  it 'treats a bare name without a port only as ours on a port we listen on (PROOF)' do
    with_backend do |backend|
      with_proxy([route_to(backend)], names: ['127.0.0.1']) do |proxy, table|
        expect(table.own_authority?('127.0.0.1', proxy.port(:udp))).to be(true)
        expect(table.own_authority?('127.0.0.1', proxy.port(:udp) + 1)).to be(false)
      end
    end
  end

  it 'still forwards the same host on a DIFFERENT port: the port is part of the authority (PROOF)' do
    with_backend do |backend|
      with_proxy([route_to(backend)], names: ['127.0.0.1']) do |proxy, _table|
        option = "coap://127.0.0.1:#{backend.bound_port}/echo"
        response = ask(proxy.port(:udp), '/', options: { 35 => option })

        expect(response).not_to be_nil
        expect(response.payload).to include('backend answered')
      end
    end
  end

  it 'rejects a route pointing at the proxy own authority at configuration time (PROOF)' do
    with_proxy([], names: ['127.0.0.1']) do |proxy, _table|
      expect do
        Takagi::Proxy::RouteTable.new(
          routes: [{ prefix: '/self', host: '127.0.0.1', port: proxy.port(:udp) }],
          names: ['127.0.0.1'], own_ports: [proxy.port(:udp)]
        )
      end.to raise_error(ArgumentError, /loop/)
    end
  end

  it 'refuses an unknown CRITICAL option on the LOCAL path with 4.02 (PROOF)' do
    with_proxy([], names: ['127.0.0.1']) do |proxy, _table|
      response = ask(proxy.port(:udp), '/local', options: { 69 => 'x' })

      expect(response).not_to be_nil
      expect(response.code).to eq(codes::BAD_OPTION)
    end
  end
end
