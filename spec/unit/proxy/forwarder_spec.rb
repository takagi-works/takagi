# frozen_string_literal: true

require 'json'

# Row 2 of .omo/plans/coap-proxy.md: the reverse-proxy request path. A request the route table
# claims goes out on the OUTBOUND hop and the backend's answer comes back to the original client;
# a request no route claims is answered locally.
#
# PROOF: nothing here exists on the untouched tree (`Takagi::Proxy` itself is row 10), so every
# example fails before this row. Routing happens in the STACK's router at call time
# (`middleware_stack.rb:75`) and the stack exposes no setter, so the one router is installed for
# the example and restored afterwards (the wiring `spec/unit/controller_threads_spec.rb:49` uses).
# The outbound hop is only visible ON THE WIRE - `Hooks.emit` is Scope::LOCAL and this server forks
# even at `worker_processes: 1` - so the backend echoes the token and Message ID it actually saw.
RSpec.describe 'Takagi::Proxy forwarding path (plan row 2)' do
  let(:stack) { Takagi::MiddlewareStack.instance }
  let(:content_code) { Takagi::CoAP::Registries::Response::CONTENT }

  before do
    @previous_router = stack.router
    @router = Takagi::Router.new
    # The proxy forwards the RELATIVE path (row 1 strips the matched prefix), so the backend is
    # mounted at the root and serves `/echo` for a client asking the proxy for `/backend/echo`.
    @router.get('/echo') do |req, _params|
      { seen_token: req.token.unpack1('H*'), seen_mid: req.message_id }
    end
    @router.get('/local/hello') { { message: 'answered locally' } }
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

  def with_proxy(route_table)
    started = Queue.new
    handler = Takagi::Hooks.subscribe(:server_starting) { |payload| started << payload }
    proxy = Takagi::Proxy.new(route_table: route_table, middleware_stack: stack, router: @router,
                              port: 0, protocols: [:udp])
    thread = Thread.new { proxy.run! }
    Timeout.timeout(5) { started.pop }
    yield proxy
  ensure
    Takagi::Hooks.unsubscribe(:server_starting, handler) if handler
    proxy&.shutdown!
    thread&.join(5)
  end

  def ask(port, path, timeout: 5)
    client = Takagi::Client.new("coap://127.0.0.1:#{port}", protocol: :udp, timeout: timeout)
    Timeout.timeout(timeout) { client.get(path) }
  ensure
    client&.close
  end

  def table_to(backend_port)
    Takagi::Proxy::RouteTable.new(
      routes: [{ prefix: '/backend', host: '127.0.0.1', port: backend_port }]
    )
  end

  it 'forwards a claimed path to the backend and returns its payload to the client (PROOF)' do
    with_backend do |backend|
      with_proxy(table_to(backend.bound_port)) do |proxy|
        response = ask(proxy.port(:udp), '/backend/echo')

        expect(response).not_to be_nil
        expect(response.code).to eq(content_code)
        echo = JSON.parse(response.payload)
        expect(echo).to include('seen_token', 'seen_mid')
        expect(echo['seen_mid']).to be_a(Integer)
      end
    end
  end

  it 're-originates the token and the Message ID on the outbound hop (PROOF)' do
    with_backend do |backend|
      with_proxy(table_to(backend.bound_port)) do |proxy|
        response = ask(proxy.port(:udp), '/backend/echo')
        echo = JSON.parse(response.payload)

        # The backend saw the OUTBOUND hop's identity; the client holds its OWN on the reply.
        expect(echo['seen_token']).to be_a(String)
        expect(echo['seen_token']).not_to eq(response.token.unpack1('H*'))
        expect(echo['seen_mid']).not_to eq(response.inbound.message_id)
      end
    end
  end

  it 'answers a path no route claims locally instead of forwarding it (PROOF)' do
    with_backend do |backend|
      with_proxy(table_to(backend.bound_port)) do |proxy|
        response = ask(proxy.port(:udp), '/local/hello')

        expect(response.code).to eq(content_code)
        expect(response.payload).to include('answered locally')
      end
    end
  end
end
