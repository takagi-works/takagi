# frozen_string_literal: true

require 'socket'
require 'timeout'
require 'uri'

RSpec.describe Takagi::Observer::Client do
  let(:server_socket) { UDPSocket.new.tap { |socket| socket.bind('0.0.0.0', 0) } }
  let(:server_port) { server_socket.addr[1] }
  let(:observe) { Takagi::CoAP::Registries::Option::OBSERVE }
  let(:uri) { "coap://localhost:#{server_port}/sensors/temp" }

  after do
    server_socket.close
  end

  def serve_registration(response_code: 69, response_options: {})
    Thread.new do
      data, addr = server_socket.recvfrom(1024)
      @client_source = addr
      request = Takagi::Message::Inbound.new(data)
      response = Takagi::Message::Outbound.new(
        code: response_code,
        payload: '{"temp":22.5}',
        token: request.token,
        type: Takagi::CoAP::Registries::MessageType::ACK,
        options: response_options
      )
      server_socket.send(response.to_bytes, 0, addr[3], addr[1])
    end
  end

  # The server pushes a notification into the client's bound socket, the way a real peer
  # would after the registration.
  def deliver_notification(client, sequence:, payload:)
    message = Takagi::Message::Outbound.new(
      code: 69, payload: payload, token: client.token,
      message_id: rand(0..0xFFFF),
      type: Takagi::CoAP::Registries::MessageType::NON,
      options: { observe => [sequence] }
    )
    server_socket.send(message.to_bytes, 0, @client_source[3], @client_source[1])
  end

  it 'reports the subscription as failed when the response carries no Observe option (6.1)' do
    serve_registration

    client = described_class.new(uri)
    notified = Queue.new
    failed = Queue.new
    client.on_notify { |_payload, _| notified << true }
    client.on_subscription_failed { |_response| failed << true }

    verdict = Timeout.timeout(5) { client.subscribe }

    expect(verdict).to eq(:failed)
    expect(failed.size).to eq(1)
    expect(notified.size).to eq(0)
  ensure
    client&.close
  end

  it 'confirms the subscription from the Observe option and delivers the response (6.1)' do
    serve_registration(response_options: { observe => [2] })

    client = described_class.new(uri)
    notified = Queue.new
    client.on_notify { |payload, inbound| notified << [payload, inbound] }

    verdict = Timeout.timeout(5) { client.subscribe }

    expect(verdict).to eq(:subscribed)
    payload, inbound = Timeout.timeout(5) { notified.pop }
    expect(payload).to eq('{"temp":22.5}')
    expect(inbound.options).to have_key(observe)
  ensure
    client&.close
  end

  describe 'freshness rule (RFC 7641 §3.4)' do
    it 'ignores a notification that is not fresher' do
      serve_registration(response_options: { observe => [4] })

      client = described_class.new(uri)
      notifications = Queue.new
      client.on_notify { |payload, _| notifications << payload }
      Timeout.timeout(5) { client.subscribe }
      # The confirmed registration response is the initial notification (sequence 4).
      expect(Timeout.timeout(5) { notifications.pop }).to eq('{"temp":22.5}')

      deliver_notification(client, sequence: 6, payload: 'newer')
      expect(Timeout.timeout(5) { notifications.pop }).to eq('newer')

      # A stale sequence must not be delivered; the fresh sentinel after it must be the
      # next thing the client reports (frames on one socket arrive in order).
      deliver_notification(client, sequence: 3, payload: 'stale')
      deliver_notification(client, sequence: 8, payload: 'current')
      expect(Timeout.timeout(5) { notifications.pop }).to eq('current')
      expect { notifications.pop(true) }.to raise_error(ThreadError)
      expect(client.last_seq).to eq(8)
    ensure
      client&.close
    end

    it 'accepts a notification with a fresh sequence' do
      serve_registration(response_options: { observe => [0] })

      client = described_class.new(uri)
      notifications = Queue.new
      client.on_notify { |payload, _| notifications << payload }
      Timeout.timeout(5) { client.subscribe }
      expect(Timeout.timeout(5) { notifications.pop }).to eq('{"temp":22.5}')

      deliver_notification(client, sequence: 1, payload: 'fresh')
      expect(Timeout.timeout(5) { notifications.pop }).to eq('fresh')
      expect(client.last_seq).to eq(1)
    ensure
      client&.close
    end
  end

  describe '#cancel' do
    it 'sends the deregistration GET with Observe: 1 (6.3)' do
      got = Queue.new
      # One serial server exchange - the registration, then the deregistration it awaits.
      # Two readers on one socket would race for the registration frame.
      server = Thread.new do
        data, addr = server_socket.recvfrom(1024)
        @client_source = addr
        request = Takagi::Message::Inbound.new(data)
        response = Takagi::Message::Outbound.new(code: 69, payload: '{"temp":22.5}',
                                                 token: request.token,
                                                 type: Takagi::CoAP::Registries::MessageType::ACK,
                                                 options: { observe => [0] })
        server_socket.send(response.to_bytes, 0, addr[3], addr[1])

        data, addr = server_socket.recvfrom(1024)
        request = Takagi::Message::Inbound.new(data)
        got << [request.options.fetch(observe), request.token]
        response = Takagi::Message::Outbound.new(code: 69, payload: '', token: request.token,
                                                 type: Takagi::CoAP::Registries::MessageType::ACK)
        server_socket.send(response.to_bytes, 0, addr[3], addr[1])
      end

      client = described_class.new(uri)
      Timeout.timeout(5) { client.subscribe }
      client.cancel

      observe_value, token = Timeout.timeout(5) { got.pop }
      expect(uint_value(observe_value)).to eq(1)
      expect(token).to eq(client.token)
    ensure
      server&.kill
      client&.close
    end

    def uint_value(bytes)
      bytes.to_s.b.bytes.reduce(0) { |acc, byte| (acc << 8) | byte }
    end
  end
end