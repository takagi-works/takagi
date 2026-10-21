# frozen_string_literal: true

require 'socket'
require 'securerandom'
require 'timeout'

# The `bind_address` key existed end to end - attr, YAML parsing, default, sig, and the shipped
# examples/takagi.yml telling users to set it - but nothing in lib/ consumed it: both transports
# hardcoded '0.0.0.0', so `bind_address: 127.0.0.1` silently produced a server on every interface.
#
# The discriminator below needs no LAN address on the machine under test: Linux makes all of
# 127.0.0.0/8 loopback, so a server bound to 127.0.0.2 answers a datagram sent to 127.0.0.2 and
# must NOT answer one sent to 127.0.0.1. Before the fix both answered, whichever address was
# configured.
RSpec.describe 'the server bind address' do
  def with_server(bind_address: nil)
    started = Queue.new
    handler = Takagi::Hooks.subscribe(:server_starting) { |payload| started << payload }
    router = Takagi::Router.new
    router.get('/echo') { |_req, _params| { ok: true } }
    options = { port: 0, worker_processes: 1, worker_threads: 1, router: router }
    options[:bind_address] = bind_address if bind_address
    server = Takagi::Server::Udp.new(**options)
    thread = Thread.new { server.run! }
    Timeout.timeout(5) { started.pop }
    yield server
  ensure
    Takagi::Hooks.unsubscribe(:server_starting, handler) if handler
    server&.shutdown!
    thread&.join(5)
  end

  def ask(host, port, family: Socket::AF_INET, timeout: 2)
    socket = UDPSocket.new(family)
    socket.bind(host, 0) if family == Socket::AF_INET
    host_form = host.include?(':') ? "[#{host}]" : host
    request = Takagi::Message::Request.new(method: :get, uri: URI("coap://#{host_form}:#{port}/echo"),
                                           token: SecureRandom.hex(4), options: {})
    socket.send(request.to_bytes, 0, host, port)
    IO.select([socket], nil, nil, timeout) ? socket.recvfrom(2048).first : nil
  ensure
    socket&.close
  end

  it 'answers only on the configured address (PROOF)' do
    with_server(bind_address: '127.0.0.2') do |server|
      expect(ask('127.0.0.2', server.bound_port)).not_to be_nil
      expect(ask('127.0.0.1', server.bound_port)).to be_nil
    end
  end

  it 'still answers on every interface by default (GUARD)' do
    with_server do |server|
      expect(ask('127.0.0.1', server.bound_port)).not_to be_nil
      expect(ask('127.0.0.2', server.bound_port)).not_to be_nil
    end
  end

  it 'binds an IPv6 address and serves over it (PROOF)' do
    with_server(bind_address: '::1') do |server|
      expect(ask('::1', server.bound_port, family: Socket::AF_INET6)).not_to be_nil
    end
  end

  it 'reaches an IPv6 peer from the client (PROOF)' do
    listener = UDPSocket.new(Socket::AF_INET6)
    listener.bind('::1', 0)
    client = Takagi::Client.new("coap://[::1]:#{listener.addr[1]}", protocol: :udp, timeout: 2)
    client.get('/echo')
    expect(IO.select([listener], nil, nil, 3)).not_to be_nil
  ensure
    client&.close
    listener&.close
  end

  describe Takagi::Network::UdpSocket do
    it 'takes the family from the address, bracketed or not' do
      expect(described_class.family_for('127.0.0.1')).to eq(Socket::AF_INET)
      expect(described_class.family_for('0.0.0.0')).to eq(Socket::AF_INET)
      expect(described_class.family_for('::1')).to eq(Socket::AF_INET6)
      expect(described_class.family_for('[::1]')).to eq(Socket::AF_INET6)
      expect(described_class.family_for('::')).to eq(Socket::AF_INET6)
    end

    it 'falls back to AF_INET for a value it cannot resolve' do
      expect(described_class.family_for('')).to eq(Socket::AF_INET)
    end
  end
end
