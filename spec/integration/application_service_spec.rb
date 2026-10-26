# frozen_string_literal: true

require 'timeout'

# An Application is a SERVICE, not just a router catalogue: the transports it builds must resolve
# every request through its composite router and its own middleware stack.
RSpec.describe 'Takagi::Application as a service' do
  after do
    Takagi::Hooks.unsubscribe(:server_starting, @subscriber) if @subscriber
  end

  def define_service
    controller = Class.new(Takagi::Controller) do
      configure { mount '/telemetry' }
      get('/data', metadata: { rt: 'sensor.data' }) { { value: 42 } }
    end
    stub_const('TelemetryController', controller)

    app = Class.new(Takagi::Application)
    app.configure { load_controllers controller }
    stub_const('TestApp', app)

    @app = app
    @app
  end

  def exchange(protocol, port, path)
    scheme = protocol == :tcp ? 'coap+tcp' : 'coap'
    client = Takagi::Client.new("#{scheme}://127.0.0.1:#{port}", protocol: protocol, timeout: 8)
    Timeout.timeout(10) { client.get(path) }
  ensure
    client&.close
  end

  # The hook is subscribed BEFORE the server exists, so the signal cannot be missed, and the wait
  # is bounded rather than a fixed sleep.
  def spawn_service(protocol)
    started = Queue.new
    @subscriber = Takagi::Hooks.subscribe(:server_starting) { |payload| started << payload }
    server = @app.spawn!(port: 0, protocols: [protocol])
    Timeout.timeout(5) { started.pop }
    server
  end

  %i[udp tcp].each do |protocol|
    it "serves a controller route over #{protocol.to_s.upcase} through the application's own stack" do
      define_service

      server = spawn_service(protocol)
      begin
        response = exchange(protocol, server.bound_port, '/telemetry/data')
        expect(response.code_name).to eq('2.05 Content')
        expect(response.payload).to include('"value":42')

        discovery = exchange(protocol, server.bound_port, '/.well-known/core')
        expect(discovery.payload).to include('</telemetry/data>')
      ensure
        server.shutdown!
      end
    end
  end

  it 'serves a route registered directly on the application, the surface plugins use' do
    app = Class.new(Takagi::Application)
    stub_const('TestApp', app)
    app.get('/health') { { ok: true } }
    @app = app

    server = spawn_service(:udp)
    begin
      response = exchange(:udp, server.bound_port, '/health')
      expect(response.code_name).to eq('2.05 Content')
      expect(response.payload).to include('"ok":true')
    ensure
      server.shutdown!
    end
  end

  it 'builds a middleware stack of its own over the composite router' do
    define_service
    @app.load_controllers!

    expect(@app.middleware_stack.router).to be(@app.router)
    expect(@app.middleware_stack).not_to be(Takagi::MiddlewareStack.instance)
  end

  it 'inherits the service lifecycle' do
    define_service

    expect(@app.method(:run!).owner).to be(Takagi::Base::ServerLifecycle)
    expect(@app.method(:boot!).super_method.owner).to be(Takagi::Base::ServerLifecycle)
    expect(@app.method(:spawn!).super_method.owner).to be(Takagi::Base::ServerLifecycle)
  end

  it 'applies service-level threads and processes to a transport' do
    app = Class.new(Takagi::Application)
    stub_const('ServiceConcurrencyApp', app)
    app.configure do
      threads 4
      processes 2
    end
    @app = app

    server = app.send(:build_servers, [:udp], 0).first
    begin
      expect(server.instance_variable_get(:@worker_threads)).to eq(4)
      expect(server.instance_variable_get(:@worker_processes)).to eq(2)
    ensure
      server.shutdown!
    end
  end

  it 'takes concurrency from a profile and lets explicit values win' do
    app = Class.new(Takagi::Application)
    stub_const('ProfiledApp', app)
    app.configure do
      profile :high_throughput
      threads 6
    end
    @app = app

    expect(app.service_settings).to include(threads: 6, processes: 8)
  end

  it 'uses the service port and protocols when spawn! is called without them' do
    app = Class.new(Takagi::Application)
    stub_const('ConfiguredApp', app)
    app.get('/health') { { ok: true } }
    app.configure do
      port 0
      protocols :udp
    end
    @app = app

    started = Queue.new
    @subscriber = Takagi::Hooks.subscribe(:server_starting) { |payload| started << payload }
    server = app.spawn!
    payload = Timeout.timeout(5) { started.pop }
    begin
      expect(payload[:protocol]).to eq(:udp)
      expect(server.bound_port).to be_positive
    ensure
      server.shutdown!
    end
  end
end
