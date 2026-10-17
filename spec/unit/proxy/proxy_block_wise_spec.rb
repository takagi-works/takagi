# frozen_string_literal: true

require 'digest'
require 'socket'

# Row 7 of .omo/plans/coap-proxy.md: block-wise passes THROUGH untouched, and what Observe does is
# pinned in one place.
#
# PROOF: nothing on the untouched tree forwards at all. Block1/Block2 (RFC 7959) are not in the
# proxy's consumed set, so a multi-block upload/download survives the hop without the proxy ever
# reassembling or re-blocking. Observe (RFC 7641) is dropped by ObservePolicy on the way out, so the
# proxy opens no observation - one response, and nothing can notify afterwards.
RSpec.describe 'Takagi::Proxy block-wise and Observe policy (plan row 7)' do
  let(:stack) { Takagi::MiddlewareStack.instance }
  let(:codes) { Takagi::CoAP::Registries::Response }

  before do
    @previous_router = stack.router
    @router = Takagi::Router.new
    @router.post('/upload') do |req, _params|
      body = req.payload.to_s
      { size: body.bytesize, digest: Digest::SHA256.hexdigest(body),
        option_numbers: req.options.keys.sort }
    end
    @router.get('/download') { { blob: 'x' * 3000 } }
    @router.get('/obs') { { message: 'one shot' } }
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

  def client_for(port)
    Takagi::Client.new("coap://127.0.0.1:#{port}", protocol: :udp, timeout: 8)
  end

  def route_to(backend, prefix)
    { prefix: prefix, host: '127.0.0.1', port: backend.bound_port }
  end

  it 'carries a multi-block upload to the backend byte for byte (PROOF)' do
    with_backend do |backend|
      with_proxy([route_to(backend, '/up')]) do |proxy|
        blob = 'y' * 3000
        client = client_for(proxy.port(:udp))
        response = Timeout.timeout(10) { client.post('/up/upload', blob) }

        expect(response).not_to be_nil
        expect(response.code).to eq(codes::CONTENT)
        seen = JSON.parse(response.payload)
        expect(seen['size']).to eq(blob.bytesize)
        expect(seen['digest']).to eq(Digest::SHA256.hexdigest(blob))
      ensure
        client&.close
      end
    end
  end

  it 'carries a multi-block download back to the client byte for byte (PROOF)' do
    with_backend do |backend|
      with_proxy([route_to(backend, '/down')]) do |proxy|
        client = client_for(proxy.port(:udp))
        response = Timeout.timeout(10) { client.get('/down/download') }

        expect(response).not_to be_nil
        expect(response.code).to eq(codes::CONTENT)
        expect(response.payload).to include('x' * 3000)
      ensure
        client&.close
      end
    end
  end

  it 'hands the backend Block2 option back to the client untouched (PROOF)' do
    with_backend do |backend|
      with_proxy([route_to(backend, '/down')]) do |proxy|
        socket = UDPSocket.new
        socket.bind('127.0.0.1', 0)
        request = Takagi::Message::Request.new(
          method: :get, uri: URI("coap://127.0.0.1:#{proxy.port(:udp)}/down/download"),
          token: SecureRandom.hex(4), options: { 23 => '' }
        )
        socket.send(request.to_bytes, 0, '127.0.0.1', proxy.port(:udp))

        raw, _address = Timeout.timeout(8) { socket.recvfrom(4096) }
        response = Takagi::Client::Response.new(raw, transport: :udp)
        expect(response.code).to eq(codes::CONTENT)
        expect(response.options).to have_key(23)
      ensure
        socket&.close
      end
    end
  end

  it 'gives an Observe request exactly one response and never a notification (PROOF)' do
    with_backend do |backend|
      with_proxy([route_to(backend, '/obs')]) do |proxy|
        socket = UDPSocket.new
        socket.bind('127.0.0.1', 0)
        request = Takagi::Message::Request.new(
          method: :get, uri: URI("coap://127.0.0.1:#{proxy.port(:udp)}/obs/obs"),
          token: SecureRandom.hex(4), options: { 6 => 0 }
        )
        socket.send(request.to_bytes, 0, '127.0.0.1', proxy.port(:udp))

        raw, _address = Timeout.timeout(8) { socket.recvfrom(4096) }
        response = Takagi::Client::Response.new(raw, transport: :udp)
        expect(response.code).to eq(codes::CONTENT)
        expect(response.options).not_to have_key(6)

        expect { Timeout.timeout(1) { socket.recvfrom(4096) } }.to raise_error(Timeout::Error)
      ensure
        socket&.close
      end
    end
  end
end
