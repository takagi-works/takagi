# frozen_string_literal: true

require 'spec_helper'
require 'socket'
require 'timeout'
require 'uri'

RSpec.describe 'RFC 7641 observe on the wire' do
  # The observed application: state-carrying topics served by a real server, observed by a
  # plain raw-socket peer that decodes what actually goes on the wire (design D10). The
  # in-house Observer::Client cannot be the oracle: it accepts any datagram whose token
  # matches, so the response to the registering GET is indistinguishable from a notification.
  # The topics live on a DEDICATED router so this spec never touches the process-global one
  # other specs depend on for discovery and routing.
  def conformance_router
    @conformance_router ||= Takagi::Router.new.tap do |router|
      router.get('/ping') { { message: 'Pong' } }
      router.topic('/sensors/temp') { { temp: 20.0, unit: 'celsius' } }
      router.topic('/observe/block-wise/big') { 'x' * 3072 }
      router.topic('/observe/block-wise/small') { 'small' }
    end
  end

  let(:observe) { Takagi::CoAP::Registries::Option::OBSERVE }
  let(:content_format) { Takagi::CoAP::Registries::Option::CONTENT_FORMAT }
  let(:block2) { Takagi::CoAP::Registries::Option::BLOCK2 }
  let(:size2) { Takagi::CoAP::Registries::Option::SIZE2 }
  let(:codes) { Takagi::CoAP::Registries::Response }
  let(:option_value) { Takagi::CoAP::BlockWise::OptionValue }

  before do
    @server = Takagi::Server::Udp.new(port: 0, worker_processes: 1, worker_threads: 1,
                                      router: conformance_router,
                                      middleware_stack: Takagi::MiddlewareStack.build(router: conformance_router))
    @server_thread = Thread.new { @server.run! }
    @port = bound_port_of(@server)
    @sockets = []
  end

  after do
    @sockets&.each(&:close)
    @server&.shutdown!
    @server_thread&.join(5)
    Takagi::ObserveRegistry.entries.clear
    reset_topic_state
  end

  # Topics hold their representation across examples; publishing an equal value is a silent
  # no-op, so each example starts from the known initial representation.
  def reset_topic_state
    conformance_router.topic_for('/sensors/temp')&.publish({ temp: 20.0, unit: 'celsius' })
    conformance_router.topic_for('/observe/block-wise/big')&.publish('x' * 3072)
    conformance_router.topic_for('/observe/block-wise/small')&.publish('small')
  end

  # Await an observable state: returns when the entry is gone inside the deadline.
  def wait_until_entry_gone(path, token:)
    endpoint = nil
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    loop do
      list = Takagi::ObserveRegistry.entries[path]
      gone = list.nil? || list.keys.none? { |(ep, tok)| tok == token }
      return true if gone

      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      raise "entry #{token} on #{path} was never removed" if remaining.negative?

      sleep 0.01
    end
  end

  def new_socket
    socket = UDPSocket.new
    socket.bind('127.0.0.1', 0)
    @sockets << socket
    socket
  end

  def send_raw(socket, path, token:, options: {})
    request = Takagi::Message::Request.new(
      method: :get, uri: URI("coap://127.0.0.1:#{@port}#{path}"), token: token, options: options
    )
    socket.send(request.to_bytes, 0, '127.0.0.1', @port)
  end

  def read_response(socket, timeout: 5)
    raise "no datagram within #{timeout}s" unless socket.wait_readable(timeout)

    Takagi::Message::Inbound.new(socket.recvfrom(65_535).first)
  end

  def assert_no_datagram(socket, window: 0.4)
    expect { Timeout.timeout(window) { socket.recvfrom(4096) } }.to raise_error(Timeout::Error)
  end

  def register(path, token:, socket: new_socket)
    send_raw(socket, path, token: token, options: { observe => 0 })
    response = read_response(socket)
    expect(response.code).to eq(codes::CONTENT)
    expect(response.options).to have_key(observe)
    response
  end

  def publish(path, value)
    topic = conformance_router.topic_for(path)
    raise "no topic #{path}" unless topic

    expect(topic.publish(value)).to be(true)
  end

  def uint_value(bytes)
    bytes.to_s.b.bytes.reduce(0) { |acc, byte| (acc << 8) | byte }
  end

  # Inbound stores a single option occurrence as the raw value, not an array.
  def option_value_of(message, number)
    Array(message.options[number]).first
  end

  it 'confirms a registration with an Observe option and the current representation (3.2)' do
    socket = new_socket
    response = register('/sensors/temp', token: 'tok1', socket: socket)

    expect(response.payload).to eq('{"temp":20.0,"unit":"celsius"}')
    expect(response.options).to have_key(content_format)

    endpoint = "127.0.0.1:#{socket.addr[1]}"
    expect(Takagi::ObserveRegistry.entries['/sensors/temp']).to have_key([endpoint, 'tok1'])
  end

  it 'refused registration is visible to the client: no Observe option on a plain route (3.2)' do
    socket = new_socket
    send_raw(socket, '/ping', token: 'tokr', options: { observe => 0 })
    response = read_response(socket)

    expect(response.code).to eq(codes::CONTENT)
    expect(response.options).not_to have_key(observe)
    expect(Takagi::ObserveRegistry.entries['/ping']).to be_nil
  end

  it 'does not duplicate a repeated registration of one endpoint and token (3.1)' do
    socket = new_socket
    register('/sensors/temp', token: 'tokr', socket: socket)
    register('/sensors/temp', token: 'tokr', socket: socket)

    expect(Takagi::ObserveRegistry.entries['/sensors/temp'].size).to eq(1)

    publish('/sensors/temp', { temp: 21.0, unit: 'celsius' })

    notification = read_response(socket)
    expect(notification.options).to have_key(observe)
    assert_no_datagram(socket)
  end

  it 'notifies with a strictly increasing Observe value on each change (4.1)' do
    socket = new_socket
    register('/sensors/temp', token: 'seq', socket: socket)

    publish('/sensors/temp', { temp: 21.0, unit: 'celsius' })
    first = read_response(socket)
    expect(first.options).to have_key(observe)

    publish('/sensors/temp', { temp: 22.0, unit: 'celsius' })
    second = read_response(socket)

    expect(second.options).to have_key(observe)
    expect(uint_value(option_value_of(second, observe))).to be > uint_value(option_value_of(first, observe))
  end

  it 'echoes the registering token to each observer (4.2)' do
    socket_a = new_socket
    socket_b = new_socket
    register('/sensors/temp', token: 'tokA', socket: socket_a)
    register('/sensors/temp', token: 'tokB', socket: socket_b)

    publish('/sensors/temp', { temp: 21.0, unit: 'celsius' })

    notification_a = read_response(socket_a)
    notification_b = read_response(socket_b)
    expect(notification_a.token).to eq('tokA')
    expect(notification_b.token).to eq('tokB')
    expect(notification_a.options).to have_key(content_format)
  end

  it 'ends the observation when the topic is deleted: one 4.04, then silence, 4.04 reads (3.3)' do
    socket = new_socket
    register('/sensors/temp', token: 'end', socket: socket)

    conformance_router.delete_topic('/sensors/temp')

    notification = read_response(socket)
    expect(notification.code).to eq(codes::NOT_FOUND)
    expect(notification.options).not_to have_key(observe)
    assert_no_datagram(socket)

    send_raw(socket, '/sensors/temp', token: 'end')
    expect(read_response(socket).code).to eq(codes::NOT_FOUND)
  ensure
    # The delete example removes the shared topic; restore it so every other example,
    # in any order, finds the declaration it registers on.
    conformance_router.topic('/sensors/temp') { { temp: 20.0, unit: 'celsius' } }
    Takagi::ObserveRegistry.entries.delete('/sensors/temp')
  end

  it 'removes an entry on a Reset in reply to a notification (5.1)' do
    socket = new_socket
    register('/sensors/temp', token: 'rst', socket: socket)

    publish('/sensors/temp', { temp: 21.0, unit: 'celsius' })
    notification = read_response(socket)

    reset = Takagi::Message::Outbound.new(
      code: '0.00', payload: '', token: '',
      message_id: notification.message_id,
      type: Takagi::CoAP::Registries::MessageType::RST
    )
    socket.send(reset.to_bytes, 0, '127.0.0.1', @port)

    wait_until_entry_gone('/sensors/temp', token: 'rst')
    publish('/sensors/temp', { temp: 22.0, unit: 'celsius' })
    assert_no_datagram(socket)
  end

  it 'deregisters explicitly with Observe: 1, without touching another endpoint (5.2)' do
    socket_a = new_socket
    socket_b = new_socket
    register('/sensors/temp', token: 'dA', socket: socket_a)
    register('/sensors/temp', token: 'dB', socket: socket_b)

    send_raw(socket_a, '/sensors/temp', token: 'dA', options: { observe => 1 })
    deregistration = read_response(socket_a)
    expect(deregistration.options).not_to have_key(observe)

    publish('/sensors/temp', { temp: 21.0, unit: 'celsius' })

    expect(read_response(socket_b).token).to eq('dB')
    assert_no_datagram(socket_a)
  end

  it 'a plain GET reads the current representation without registering (topics)' do
    socket = new_socket
    send_raw(socket, '/sensors/temp', token: 'plain')
    response = read_response(socket)

    expect(response.code).to eq(codes::CONTENT)
    expect(response.options).not_to have_key(observe)
    expect(Takagi::ObserveRegistry.entries['/sensors/temp']).to be_nil
  end

  it 'delivers a large notification as the first block of a block-wise sequence (4.3)' do
    socket = new_socket
    register('/observe/block-wise/big', token: 'blk', socket: socket)

    publish('/observe/block-wise/big', 'y' * 3072)

    notification = read_response(socket)
    block = option_value.decode(option_value_of(notification, block2))

    expect(notification.token).to eq('blk')
    expect(block.num).to eq(0)
    expect(block.more?).to be(true)
    expect(block.szx).to eq(6)
    expect(notification.payload.bytesize).to eq(1024)
    expect(uint_value(option_value_of(notification, size2))).to eq(3072)
  end

  it 'the documented client call sequence - subscribe, notified, cancel - runs against a real server (6.4)' do
    observer = Takagi::Observer::Client.new("coap://127.0.0.1:#{@port}/sensors/temp")
    notifications = Queue.new
    observer.on_notify { |payload, _| notifications << payload }

    verdict = Timeout.timeout(5) { observer.subscribe }
    expect(verdict).to eq(:subscribed)
    # The confirmed registration response is the initial notification (current state).
    expect(Timeout.timeout(5) { notifications.pop }).to include('20.0')

    publish('/sensors/temp', { temp: 30.0, unit: 'celsius' })
    expect(Timeout.timeout(5) { notifications.pop }).to include('30.0')

    observer.cancel
    wait_until_entry_gone('/sensors/temp', token: observer.token)
    publish('/sensors/temp', { temp: 31.0, unit: 'celsius' })
    expect { Timeout.timeout(0.5) { notifications.pop } }.to raise_error(Timeout::Error)
  ensure
    observer&.close
  end

  it 'leaves a small topic and its notification unchanged (4.3)' do
    socket = new_socket
    register('/observe/block-wise/small', token: 'sm', socket: socket)

    publish('/observe/block-wise/small', 'tiny')
    notification = read_response(socket)

    expect(notification.payload).to eq('tiny')
    expect(notification.options).not_to have_key(block2)
    expect(notification.options).not_to have_key(size2)
  end
end