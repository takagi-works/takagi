# frozen_string_literal: true

RSpec.describe Takagi::Observer::Client do
  let(:uri) { 'coap://127.0.0.1:5683/foo' }
  let(:client) { described_class.new(uri) }
  let(:observe) { Takagi::CoAP::Registries::Option::OBSERVE }

  def stub_reply(response_options:)
    fake_socket = instance_double(UDPSocket)
    allow(UDPSocket).to receive(:new).and_return(fake_socket)
    allow(fake_socket).to receive(:send)
    allow(fake_socket).to receive(:closed?).and_return(false)
    allow(fake_socket).to receive(:close)
    allow(fake_socket).to receive(:recvfrom_nonblock) do
      response = Takagi::Message::Outbound.new(
        code: '2.05 Content',
        payload: 'Hello World',
        token: client.instance_variable_get(:@token),
        type: Takagi::CoAP::Registries::MessageType::ACK,
        options: response_options
      ).to_bytes
      [response, ['127.0.0.1', 5683]]
    end
    fake_socket
  end

  it 'sends an observe request and delivers the confirmed response as a notification' do
    fake_socket = stub_reply(response_options: { observe => [0] })
    received = Queue.new
    client.on_notify { |payload, _| received << payload }

    verdict = Timeout.timeout(1) { client.subscribe }

    expect(verdict).to eq(:subscribed)
    expect(fake_socket).to have_received(:send)
    expect(Timeout.timeout(1) { received.pop }).to eq('Hello World')
  ensure
    client.close
  end

  it 'closing the client while the listener waits does not kill the listener thread with an exception' do
    fake_socket = instance_double(UDPSocket)
    allow(UDPSocket).to receive(:new).and_return(fake_socket)
    allow(fake_socket).to receive(:send)
    allow(fake_socket).to receive(:closed?).and_return(false)
    allow(fake_socket).to receive(:close)
    entered_wait = Queue.new
    release_wait = Queue.new
    reads = 0
    allow(fake_socket).to receive(:recvfrom_nonblock) do
      reads += 1
      raise IOError, 'closed' if reads > 1

      raise IO::EAGAINWaitReadable
    end
    allow(fake_socket).to receive(:wait_readable) do
      entered_wait << true
      release_wait.pop
      raise IOError, 'stream closed in another thread'
    end
    client.instance_variable_set(:@running, true)

    outcome = Queue.new
    thread = Thread.new do
      client.send(:handle_notification_iteration) while client.instance_variable_get(:@running)
      outcome << :clean
    rescue StandardError => e
      outcome << e
    end

    Timeout.timeout(5) { entered_wait.pop }
    client.stop
    release_wait << :go

    expect(Timeout.timeout(5) { outcome.pop }).to eq(:clean)
    expect(thread.join(2)).to be(thread)
    expect(thread.alive?).to be(false)
  ensure
    release_wait << :go unless release_wait.empty?
    Thread.kill(thread) if thread&.alive?
  end
end