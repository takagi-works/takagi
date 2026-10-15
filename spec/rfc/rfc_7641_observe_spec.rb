# frozen_string_literal: true

require 'spec_helper'
require 'socket'
require 'timeout'
require 'uri'

RSpec.describe Takagi::Observer::Client do
  let(:server_port) { find_free_port }
  let(:server_socket) { UDPSocket.new }
  let(:notify_payload) { '{"temp":22.5}' }
  let(:uri) { "coap://localhost:#{server_port}/sensors/temp" }

  before do
    server_socket.bind('0.0.0.0', server_port)
  end

  after do
    server_socket.close
  end

  it 'sends observe request and receives notification' do
    queue = Queue.new
    subscribed = Queue.new

    server_thread = Thread.new do
      data, addr = server_socket.recvfrom(1024)
      request = Takagi::Message::Inbound.new(data)

      # A GET carrying the Observe option is an Observe request; the registration value 0
      # is the zero-length integer encoding of 0 (RFC 7641 §3.1, RFC 7252 §3.2).
      expect(request.observe?).to be(true)
      expect(request.options).to have_key(6)

      response = Takagi::Message::Outbound.new(
        code: 69,
        payload: notify_payload,
        token: request.token,
        type: 2
      )
      Timeout.timeout(5) { subscribed.pop }
      server_socket.send(response.to_bytes, 0, addr[3], addr[1])
    end

    client = Takagi::Observer::Client.new(uri)
    client.on_notify do |payload, _|
      queue.push(payload)
    end

    client.subscribe
    subscribed.push(:ready)

    result = nil
    Timeout.timeout(2) { result = queue.pop }

    expect(result).to eq(notify_payload)

    server_thread.kill
  end
end

RSpec.describe Takagi::Reactor do
  let(:reactor) { Takagi::Reactor.new }

  it 'registers remote observe' do
    uri = "coap://localhost:5683/sensors/temp"
    handler = proc { |_payload, _inbound| }

    # Allow initialization logs, then expect the observe log
    allow(Takagi.logger).to receive(:info)
    expect(Takagi.logger).to receive(:info).with("Observing remote resource: #{uri}")
    reactor.observe(uri, &handler)

    # New reactor uses @observers hash instead of @observes array
    expect(reactor.observers.size).to eq(1)
    expect(reactor.observers[uri][:uri]).to eq(uri)
  end

  it 'notifies observer handlers when triggered' do
    uri = "coap://localhost:5683/sensors/temp"
    queue = Queue.new

    reactor.observe(uri) do |payload, _|
      queue.push(payload)
    end

    reactor.trigger_observe(uri, '{"temp":30.0}')

    result = nil
    Timeout.timeout(2) { result = queue.pop }

    expect(result).to eq('{"temp":30.0}')
  end
end

RSpec.describe 'Takagi Observe End-to-End' do
  let(:queue) { Queue.new }
  port = find_free_port

  def wait_until_serving(server_port, deadline_seconds: 10)
    probe = UDPSocket.new
    request = Takagi::Message::Request.new(
      method: :get,
      uri: URI("coap://127.0.0.1:#{server_port}/ping"),
      token: 'rdy'
    )
    bytes = request.to_bytes
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + deadline_seconds
    loop do
      probe.send(bytes, 0, '127.0.0.1', server_port)
      return if probe.wait_readable(0.25)

      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      raise "server on port #{server_port} never became ready" if remaining.negative?
    end
  ensure
    probe&.close
  end

  def stop_forked_server(pid)
    Process.kill('INT', pid)
    Timeout.timeout(5) { Process.wait(pid) }
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  rescue Timeout::Error
    Process.kill('KILL', pid)
    Process.wait(pid)
  end

  before(:all) do
    @server_pid = fork do
        class TestApp < Takagi::Base
          reactor do
            observable "/sensors/temp" do
              { temp: 42.0 }
            end
          end
        end

        TestApp.run!(port: ENV['PORT'] || port)
      end
      wait_until_serving(port)
  end

  after(:all) do
    stop_forked_server(@server_pid)
  end

  it 'observes server observable' do
    client = Takagi::Observer::Client.new("coap://localhost:#{port}/sensors/temp")
    client.on_notify do |payload, _|
      queue.push(payload)
    end

    client.subscribe

    result = nil
    Timeout.timeout(5) { result = queue.pop }

    expect(result).to include("temp")
  end
end

# Observable resources for the block-wise observe examples. The handlers return plain
# Strings, so a notification value and the representation a GET serves are the same
# bytes; `discovery: true` keeps the spec-only routes out of /.well-known/core.
class ObserveBlockWiseSpecApp < Takagi::Base
  BIG = 'x' * 3072
  SMALL = 'small'
  BIG_PATH = '/observe/block-wise/big'
  SMALL_PATH = '/observe/block-wise/small'

  observable BIG_PATH, metadata: { discovery: true } do
    BIG
  end

  observable SMALL_PATH, metadata: { discovery: true } do
    SMALL
  end
end

RSpec.describe 'Takagi Observe + Block2' do
  let(:option_value) { Takagi::CoAP::BlockWise::OptionValue }
  let(:observe) { Takagi::CoAP::Registries::Option::OBSERVE }
  let(:block2) { Takagi::CoAP::Registries::Option::BLOCK2 }
  let(:size2) { Takagi::CoAP::Registries::Option::SIZE2 }
  let(:etag) { Takagi::CoAP::Registries::Option::ETAG }

  before do
    @previous_stack = Takagi.config.middleware.stack
    Takagi.config.middleware.stack = [{ name: 'BlockWise', options: {} }]
    Takagi::MiddlewareStack.instance.reset!

    @port = find_free_port
    @server = Takagi::Server::Udp.new(port: @port, worker_processes: 1, worker_threads: 1,
                                      watcher: Takagi::Observer::Watcher.new(interval: 60))
    @server_thread = Thread.new { @server.run! }
    @subscriber = UDPSocket.new
    @subscriber.bind('127.0.0.1', 0)
  end

  after do
    [ObserveBlockWiseSpecApp::BIG_PATH, ObserveBlockWiseSpecApp::SMALL_PATH].each do |path|
      Takagi::ObserveRegistry.unsubscribe(path, 'obs-blk')
      Takagi::ObserveRegistry.unsubscribe(path, 'obs-small')
    end
    @subscriber&.close
    @server&.shutdown!
    @server_thread&.join(5)
    Takagi.config.middleware.stack = @previous_stack
    Takagi::MiddlewareStack.instance.reset!
  end

  # The real client observes the resource: a GET with the Observe option, which is how
  # RFC 7641 delivers the current state of an observable.
  def observe_with_client(path)
    client = Takagi::Client.new("coap://127.0.0.1:#{@port}", timeout: 5)
    client.get(path, options: { observe => 0 })
  ensure
    client&.close
  end

  # A raw subscriber exchange, used to fetch the blocks a notification announced the
  # way an observing client would.
  def raw_get(path, options: {}, token: 'cont-blk')
    uri = URI("coap://127.0.0.1:#{@port}#{path}")
    request = Takagi::Message::Request.new(method: :get, uri: uri, token: token, options: options)
    @subscriber.send(request.to_bytes, 0, '127.0.0.1', @port)
    raise 'no CoAP response within 5s' unless @subscriber.wait_readable(5)

    Takagi::Message::Inbound.new(@subscriber.recvfrom(65_535).first)
  end

  def option(message, number)
    Array(message.respond_to?(:option) ? message.option(number) : message.options[number]).first
  end

  def uint_value(bytes)
    bytes.to_s.b.bytes.reduce(0) { |acc, byte| (acc << 8) | byte }
  end

  it 'serves a 3 KiB observable to the real client as blocks it reassembles byte-for-byte' do
    response = observe_with_client(ObserveBlockWiseSpecApp::BIG_PATH)

    expect(response.success?).to be(true)
    expect(response.payload).to eq(ObserveBlockWiseSpecApp::BIG)
    expect(response.options).not_to have_key(block2)
  end

  it 'reassembles a 3 KiB observable through the public #observe entry point' do
    client = Takagi::Client.new("coap://127.0.0.1:#{@port}", timeout: 5)

    response = client.observe(ObserveBlockWiseSpecApp::BIG_PATH)

    expect(response.success?).to be(true)
    expect(response.payload).to eq(ObserveBlockWiseSpecApp::BIG)
    expect(response.options).not_to have_key(block2)
  ensure
    client&.close
  end

  it 'delivers a notification that exceeds one datagram as the first block of that sequence' do
    path = ObserveBlockWiseSpecApp::BIG_PATH
    Takagi::ObserveRegistry.subscribe(path, address: '127.0.0.1', port: @subscriber.addr[1], token: 'obs-blk')

    Takagi::ObserveRegistry.notify(path, ObserveBlockWiseSpecApp::BIG)

    expect(@subscriber.wait_readable(5)).to be_truthy
    data, = @subscriber.recvfrom(65_535)
    notification = Takagi::Message::Inbound.new(data)
    block = option_value.decode(option(notification, block2))

    expect(notification.token).to eq('obs-blk')
    expect(block.num).to eq(0)
    expect(block.more?).to be(true)
    expect(block.szx).to eq(6)
    expect(data.bytesize).to be < 1200
    expect(notification.payload).to eq(ObserveBlockWiseSpecApp::BIG.byteslice(0, 1024))
    expect(uint_value(option(notification, size2))).to eq(ObserveBlockWiseSpecApp::BIG.bytesize)
    expect(option(notification, etag).bytesize).to eq(8)

    # The announced representation is retrievable: the notification's first block and
    # the blocks a GET serves belong to one sequence, with the same ETag and byte-exact
    # payloads, and the real client reassembles the whole representation.
    continuation = raw_get(path, options: { observe => 0, block2 => option_value.encode(num: 1, more: false, szx: 6) })
    expect(option(continuation, etag)).to eq(option(notification, etag))
    expect(continuation.payload).to eq(ObserveBlockWiseSpecApp::BIG.byteslice(1024, 1024))

    response = observe_with_client(path)
    expect(response.payload).to eq(ObserveBlockWiseSpecApp::BIG)
    expect(Array(response.options[etag]).first).to eq(option(notification, etag))
    expect(response.payload.byteslice(0, 1024)).to eq(notification.payload)
  end

  it 'leaves a small observable and its notification unchanged' do
    path = ObserveBlockWiseSpecApp::SMALL_PATH

    response = observe_with_client(path)
    expect(response.payload).to eq(ObserveBlockWiseSpecApp::SMALL)
    expect(response.options).not_to have_key(block2)

    Takagi::ObserveRegistry.subscribe(path, address: '127.0.0.1', port: @subscriber.addr[1], token: 'obs-small')
    Takagi::ObserveRegistry.notify(path, ObserveBlockWiseSpecApp::SMALL)

    expect(@subscriber.wait_readable(5)).to be_truthy
    notification = Takagi::Message::Inbound.new(@subscriber.recvfrom(65_535).first)

    expect(notification.payload).to eq(ObserveBlockWiseSpecApp::SMALL)
    expect(option(notification, block2)).to be_nil
    expect(option(notification, size2)).to be_nil
  end
end
