# frozen_string_literal: true

require 'timeout'

# The proxy's two mapping modes: a prefixed route is a NAMESPACE mount (the prefix is stripped),
# while a transparent route uses its prefix only to select the backend and forwards the client's
# path unchanged. CoRE aggregation follows the same rule - a transparent route must not re-prefix
# the links its backend already advertises.
RSpec.describe 'Takagi::Proxy transparent routing' do
  def ask(port, path)
    client = Takagi::Client.new("coap://127.0.0.1:#{port}", protocol: :udp, timeout: 8)
    Timeout.timeout(10) { client.get(path) }
  ensure
    client&.close
  end

  def with_backend(router)
    started = Queue.new
    subscriber = Takagi::Hooks.subscribe(:server_starting) { |payload| started << payload }
    stack = Takagi::MiddlewareStack.build(router: router)
    server = Takagi::Server::Udp.new(port: 0, worker_processes: 1, worker_threads: 1,
                                     router: router, middleware_stack: stack)
    thread = Thread.new { server.run! }
    Timeout.timeout(5) { started.pop }
    yield server
  ensure
    Takagi::Hooks.unsubscribe(:server_starting, subscriber) if subscriber
    server&.shutdown!
    thread&.join(5)
  end

  def with_proxy(table)
    started = Queue.new
    subscriber = Takagi::Hooks.subscribe(:server_starting) { |payload| started << payload }
    proxy = Takagi::Proxy.new(route_table: table, port: 0, protocols: [:udp], worker_processes: 1)
    thread = Thread.new { proxy.run! }
    Timeout.timeout(5) { started.pop }
    yield proxy
  ensure
    Takagi::Hooks.unsubscribe(:server_starting, subscriber) if subscriber
    proxy&.shutdown!
    thread&.join(5)
  end

  let(:router) do
    Takagi::Router.new.tap do |backend|
      backend.get('/hello') { |req| { path: req.uri.path } }
      backend.get('/prefix/hello') { |req| { path: req.uri.path } }
      backend.get('/any/deep') { |req| { path: req.uri.path } }
      backend.get('/.well-known/core') do |req|
        req.to_response('2.05 Content',
                        '</prefix/hello>;rt="a",</hello>;rt="b",</any/deep>;rt="c"',
                        options: { Takagi::CoAP::Registries::Option::CONTENT_FORMAT => 0 })
      end
    end
  end

  it 'forwards the path unchanged and leaves the CoRE links alone (PROOF)' do
    with_backend(router) do |backend|
      table = Takagi::Proxy::RouteTable.new(
        routes: [{ prefix: '/prefix', strip_prefix: false, host: '127.0.0.1', port: backend.bound_port }],
        discovery: :aggregate
      )

      with_proxy(table) do |proxy|
        response = ask(proxy.port(:udp), '/prefix/hello')
        expect(response.code_name).to eq('2.05 Content')
        expect(response.payload).to include('"/prefix/hello"')

        discovery = ask(proxy.port(:udp), '/.well-known/core')
        expect(discovery.payload).to include('</prefix/hello>')
        expect(discovery.payload).not_to include('</prefix/prefix/hello>')
      end
    end
  end

  it 'strips a prefixed route and rewrites its CoRE links under the prefix (GUARD)' do
    with_backend(router) do |backend|
      table = Takagi::Proxy::RouteTable.new(
        routes: [{ prefix: '/telemetry', host: '127.0.0.1', port: backend.bound_port }],
        discovery: :aggregate
      )

      with_proxy(table) do |proxy|
        response = ask(proxy.port(:udp), '/telemetry/hello')
        expect(response.code_name).to eq('2.05 Content')
        expect(response.payload).to include('"/hello"')

        discovery = ask(proxy.port(:udp), '/.well-known/core')
        expect(discovery.payload).to include('</telemetry/hello>')
        expect(discovery.payload).to include('</telemetry/prefix/hello>')
      end
    end
  end

  it 'accepts a route with no prefix as a transparent catch-all (PROOF)' do
    with_backend(router) do |backend|
      table = Takagi::Proxy::RouteTable.new(routes: [{ host: '127.0.0.1', port: backend.bound_port }])

      with_proxy(table) do |proxy|
        response = ask(proxy.port(:udp), '/any/deep')
        expect(response.code_name).to eq('2.05 Content')
        expect(response.payload).to include('"/any/deep"')
      end
    end
  end
end
