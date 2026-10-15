# frozen_string_literal: true

require 'digest'
require 'json'

RSpec.describe Takagi::Client do
  describe 'unified API' do
    describe 'protocol detection' do
      it 'detects UDP from coap:// scheme' do
        client = described_class.new('coap://localhost:5683')
        expect(client.instance_variable_get(:@protocol)).to eq(:udp)
        expect(client.instance_variable_get(:@impl)).to be_a(Takagi::UdpClient)
        client.close
      end

      it 'detects TCP from coap+tcp:// scheme' do
        client = described_class.new('coap+tcp://localhost:5683')
        expect(client.instance_variable_get(:@protocol)).to eq(:tcp)
        expect(client.instance_variable_get(:@impl)).to be_a(Takagi::TcpClient)
        client.close
      end

      it 'defaults to UDP when no scheme is provided' do
        client = described_class.new('localhost:5683')
        expect(client.instance_variable_get(:@protocol)).to eq(:udp)
        expect(client.instance_variable_get(:@impl)).to be_a(Takagi::UdpClient)
        client.close
      end
    end

    describe 'explicit protocol parameter' do
      it 'uses UDP when protocol: :udp is specified' do
        client = described_class.new('localhost:5683', protocol: :udp)
        expect(client.instance_variable_get(:@protocol)).to eq(:udp)
        expect(client.instance_variable_get(:@impl)).to be_a(Takagi::UdpClient)
        client.close
      end

      it 'uses TCP when protocol: :tcp is specified' do
        client = described_class.new('localhost:5683', protocol: :tcp)
        expect(client.instance_variable_get(:@protocol)).to eq(:tcp)
        expect(client.instance_variable_get(:@impl)).to be_a(Takagi::TcpClient)
        client.close
      end

      it 'overrides URI scheme when protocol is explicitly specified' do
        client = described_class.new('coap://localhost:5683', protocol: :tcp)
        expect(client.instance_variable_get(:@protocol)).to eq(:tcp)
        expect(client.instance_variable_get(:@impl)).to be_a(Takagi::TcpClient)
        client.close
      end
    end

    describe 'block-based initialization' do
      it 'yields client and auto-closes with UDP' do
        closed_inside = nil

        described_class.new('coap://localhost:5683') do |client|
          closed_inside = client.closed?
          expect(client.instance_variable_get(:@impl)).to be_a(Takagi::UdpClient)
        end

        expect(closed_inside).to be false
      end

      it 'yields client and auto-closes with TCP' do
        closed_inside = nil

        described_class.new('localhost:5683', protocol: :tcp) do |client|
          closed_inside = client.closed?
          expect(client.instance_variable_get(:@impl)).to be_a(Takagi::TcpClient)
        end

        expect(closed_inside).to be false
      end

      it 'auto-closes even when an error occurs' do
        client_ref = nil

        expect do
          described_class.new('coap://localhost:5683') do |client|
            client_ref = client
            raise 'Test error'
          end
        end.to raise_error('Test error')

        sleep 0.2 # Give thread time to stop
        expect(client_ref.closed?).to be true
      end
    end

    describe 'manual lifecycle management' do
      it 'requires explicit close without block' do
        client = described_class.new('coap://localhost:5683')
        expect(client.closed?).to be false

        client.close
        expect(client.closed?).to be true
      end

      it 'delegates close to implementation' do
        client = described_class.new('coap://localhost:5683')
        impl = client.instance_variable_get(:@impl)

        expect(impl).to receive(:close).and_call_original
        client.close
      end
    end

    describe 'method delegation' do
      it 'delegates get, post, put, delete to implementation' do
        client = described_class.new('coap://localhost:5683')

        expect(client).to respond_to(:get)
        expect(client).to respond_to(:post)
        expect(client).to respond_to(:put)
        expect(client).to respond_to(:delete)
        expect(client).to respond_to(:on)
        expect(client).to respond_to(:ping)

        client.close
      end

      it 'delegates callbacks to implementation' do
        client = described_class.new('coap://localhost:5683')
        impl = client.instance_variable_get(:@impl)

        callback = proc { |response| response }
        client.on(:response, &callback)

        expect(impl.callbacks[:response]).to eq(callback)
        client.close
      end
    end

    describe 'error handling' do
      it 'raises error for unknown protocol' do
        # Manually set invalid protocol
        expect do
          client = described_class.allocate
          client.instance_variable_set(:@protocol, :invalid)
          client.send(:create_client_impl, 'localhost:5683', 5, true)
        end.to raise_error(ArgumentError, /Unknown protocol/)
      end
    end
  end

  describe 'block-wise transfer through the unified client' do
    def with_server(scheme, protocol)
      port = find_free_port
      server = Takagi::Base.spawn!(port: port, protocols: [protocol])
      client = described_class.new("#{scheme}://127.0.0.1:#{port}", protocol: protocol, timeout: 10)
      yield(client)
    ensure
      client&.close
      server&.shutdown!
    end

    it 'reassembles a large representation and uploads a large body over UDP' do
      with_server('coap', :udp) do |client|
        body = 'z' * 4096
        expect(round_trip(client, body)).to eq('size' => 4096, 'digest' => Digest::SHA256.hexdigest(body))
      end
    end

    it 'carries a large representation and body in one frame over TCP' do
      with_server('coap+tcp', :tcp) do |client|
        body = 'z' * 4096
        expect(round_trip(client, body)).to eq('size' => 4096, 'digest' => Digest::SHA256.hexdigest(body))
      end
    end

    # One large GET and one large POST through the public client API, returning the
    # handler's report of the body it received.
    def round_trip(client, representation)
      response = nil
      client.get('/client-block-wise/big') { |res| response = res }
      expect(response.payload).to eq(big_representation)

      echo = nil
      client.post('/client-block-wise/echo', representation) { |res| echo = res }

      JSON.parse(echo.payload)
    end

    it 'posts a large JSON body to the built-in echo route and reads the large reply' do
      with_server('coap', :udp) do |client|
        message = 'y' * 4096
        echoed = nil

        client.post_json('/echo', { message: message }) { |res| echoed = res }

        expect(JSON.parse(echoed.payload)).to eq('echo' => message)
      end
    end
  end

  describe 'liveness probe' do
    def with_protocol_server(protocol)
      port = find_free_port
      server = Takagi::Base.spawn!(port: port, protocols: [protocol])
      scheme = protocol == :tcp ? 'coap+tcp' : 'coap'
      client = described_class.new("#{scheme}://127.0.0.1:#{port}", timeout: 2)
      yield(client)
    ensure
      client&.close
      server&.shutdown!
    end

    def closed_tcp_port
      server = TCPServer.new('127.0.0.1', 0)
      port = server.addr[1]
      server.close
      port
    end

    it 'reports a spawned UDP server as alive' do
      with_protocol_server(:udp) { |client| expect(client.ping).to be true }
    end

    it 'reports a spawned TCP server as alive' do
      with_protocol_server(:tcp) { |client| expect(client.ping).to be true }
    end

    it 'reports a closed UDP port as not alive within the timeout instead of raising' do
      client = described_class.new("coap://127.0.0.1:#{find_free_port}", timeout: 1)

      started = Time.now
      alive = client.ping
      elapsed = Time.now - started

      expect(alive).to be false
      expect(elapsed).to be < 2.5
    ensure
      client&.close
    end

    it 'reports a closed TCP port as not alive within the timeout instead of raising' do
      client = described_class.new("coap+tcp://127.0.0.1:#{closed_tcp_port}", timeout: 1)

      started = Time.now
      alive = client.ping
      elapsed = Time.now - started

      expect(alive).to be false
      expect(elapsed).to be < 2.5
    ensure
      client&.close
    end
  end
end
