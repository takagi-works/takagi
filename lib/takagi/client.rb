# frozen_string_literal: true

require 'socket'
require 'forwardable'
require_relative 'client_base'
require_relative 'message/retransmission_manager'

module Takagi
  # Unified Takagi Client for communicating with Takagi servers over CoAP.
  #
  # Supports multiple protocols (UDP, TCP) with automatic protocol detection
  # based on URI scheme or explicit protocol parameter.
  #
  # @example Block-based with protocol auto-detection (recommended)
  #   Takagi::Client.new('coap://localhost:5683') do |client|
  #     client.get('/temperature')
  #   end
  #
  # @example Block-based with explicit protocol
  #   Takagi::Client.new('localhost:5683', protocol: :tcp) do |client|
  #     client.get('/temperature')
  #   end
  #
  # @example Manual lifecycle management
  #   client = Takagi::Client.new('coap://localhost:5683')
  #   begin
  #     client.get('/temperature')
  #   ensure
  #     client.close
  #   end
  class Client < ClientBase
    extend Forwardable

    # Delegate public methods to the implementation
    def_delegators :@impl, :server_uri, :timeout, :callbacks, :closed?
    def_delegators :@impl, :get, :post, :put, :delete, :on
    def_delegators :@impl, :get_json, :post_json, :put_json, :close

    # Creates a new client and optionally yields it to a block.
    #
    # @param server_uri [String] URL of the Takagi server (e.g., 'coap://localhost:5683', 'localhost:5683')
    # @param timeout [Integer] Maximum time to wait for a response
    # @param protocol [Symbol, nil] Protocol to use (:udp, :tcp, or nil for auto-detection from URI)
    # @param use_retransmission [Boolean] Enable RFC 7252 §4.2 compliant retransmission for UDP (default: true)
    # @yield [client] Optionally yields the client to a block and auto-closes afterward
    # @return [Client, Object] Returns the client instance, or the block's return value if a block is given
    #
    # @example Protocol auto-detection from URI
    #   client = Takagi::Client.new('coap://localhost:5683')      # Uses UDP
    #   client = Takagi::Client.new('coap+tcp://localhost:5683')  # Uses TCP
    #
    # @example Explicit protocol specification
    #   client = Takagi::Client.new('localhost:5683', protocol: :tcp)
    #   client = Takagi::Client.new('localhost:5683', protocol: :udp)
    #
    # @example With block (auto-close)
    #   Takagi::Client.new('coap://localhost:5683') do |client|
    #     client.get('/resource')
    #   end
    def initialize(server_uri, timeout: 5, protocol: nil, use_retransmission: true)
      # Detect protocol from URI if not explicitly specified
      @protocol = protocol || detect_protocol(server_uri)

      # Delegate to the appropriate client implementation
      @impl = create_client_impl(server_uri, timeout, use_retransmission)

      # If a block is given, yield and auto-close
      return unless block_given?

      begin
        yield(self)
      ensure
        close
      end
    end

    private

    # Detects the protocol from the URI scheme using transport registry
    # @param uri_string [String] The URI to parse
    # @return [Symbol] :tcp or :udp
    def detect_protocol(uri_string)
      uri = URI(uri_string.start_with?('coap') ? uri_string : "coap://#{uri_string}")

      # NEW: Use transport registry to find transport for scheme
      transport = Takagi::Network::Registry.for_scheme(uri.scheme)

      if transport
        # Map transport class to symbol
        case transport.scheme
        when 'coap+tcp', 'coaps+tcp'
          :tcp
        else
          :udp
        end
      else
        :udp # Default to UDP if transport not found
      end
    rescue URI::InvalidURIError, Takagi::Network::Registry::TransportNotFoundError
      :udp # Default to UDP if URI parsing fails or transport not found
    end

    # Creates the appropriate client implementation based on protocol
    # @param server_uri [String] Server URI
    # @param timeout [Integer] Request timeout
    # @param use_retransmission [Boolean] Enable retransmission for UDP
    # @return [UdpClient, TcpClient] The client implementation
    def create_client_impl(server_uri, timeout, use_retransmission)
      # Normalize URI to include scheme if not present
      normalized_uri = normalize_uri(server_uri)

      case @protocol
      when :tcp
        require_relative 'tcp_client'
        TcpClient.new(normalized_uri, timeout: timeout)
      when :udp
        UdpClient.new(normalized_uri, timeout: timeout, use_retransmission: use_retransmission)
      else
        raise ArgumentError, "Unknown protocol: #{@protocol}. Use :udp or :tcp"
      end
    end

    # Normalizes URI to include appropriate scheme
    # @param uri_string [String] The URI string
    # @return [String] Normalized URI with scheme
    def normalize_uri(uri_string)
      return uri_string if uri_string.start_with?('coap')

      scheme = @protocol == :tcp ? 'coap+tcp' : 'coap'
      "#{scheme}://#{uri_string}"
    end
  end

  # UDP-specific client implementation (internal)
  # Users should use Takagi::Client with protocol: :udp instead
  class UdpClient < ClientBase
    # Initializes the UDP client
    # @param server_uri [String] URL of the Takagi server
    # @param timeout [Integer] Maximum time to wait for a response
    # @param use_retransmission [Boolean] Enable RFC 7252 §4.2 compliant retransmission (default: true)
    def initialize(server_uri, timeout: 5, use_retransmission: true)
      super(server_uri, timeout: timeout)
      @use_retransmission = use_retransmission

      return unless @use_retransmission

      @retransmission_manager = Takagi::Message::RetransmissionManager.new
      @retransmission_manager.start
    end

    protected

    # Stops the retransmission manager thread
    def cleanup_resources
      @retransmission_manager&.stop
      super
    end

    private

    # Executes a request to the server using Takagi::Message::Request
    # @param method [Symbol] HTTP method (:get, :post, :put, :delete)
    # @param path [String] Resource path
    # @param payload [String] (optional) Data for POST/PUT requests
    # @param options [Hash] (optional) CoAP options { option_number => value }
    # @param type [Integer, nil] (optional) CoAP message type
    # @param callback [Proc] (optional) Callback function for processing the response
    def request(method, path, payload = nil, options: {}, type: nil, &callback)
      uri = URI.join(server_uri.to_s, path)
      message = Takagi::Message::Request.new(
        method: method,
        uri: uri,
        payload: payload,
        type: type,
        options: options
      )

      if @use_retransmission
        request_with_retransmission(message, uri, &callback)
      else
        request_simple(message, uri, &callback)
      end
    end

    # Simple request without retransmission (legacy mode)
    def request_simple(message, uri, &callback)
      socket = UDPSocket.new
      socket.send(message.to_bytes, 0, uri.host, uri.port || 5683)

      unless socket.wait_readable(@timeout)
        puts 'TakagiClient Error: Request timeout'
        return
      end

      response, = socket.recvfrom(1024)
      deliver_raw_response(response, &callback)
    rescue StandardError => e
      puts "TakagiClient Error: #{e.message}"
    ensure
      socket&.close unless socket&.closed?
    end

    # RFC 7252 §4.2 compliant request with automatic retransmission
    def request_with_retransmission(message, uri, &callback)
      socket = UDPSocket.new
      state = send_with_retransmission(message, socket, uri)
      socket.close
      handle_response_state(state, &callback)
    rescue StandardError => e
      puts "TakagiClient Error: #{e.message}"
    end

    def send_with_retransmission(message, socket, uri)
      state = { response_received: false, response_data: nil, error: nil }

      @retransmission_manager.send_confirmable(
        message.message_id, message.to_bytes, socket, uri.host, uri.port || 5683
      ) { |resp, err| update_state(state, resp, err) }

      wait_for_response(message, socket, state)
      state
    end

    def wait_for_response(message, socket, state)
      start_time = Time.now
      check_socket_for_response(message, socket, state) until state[:response_received] || (Time.now - start_time) > @timeout
    end

    def check_socket_for_response(message, socket, state)
      return unless socket.wait_readable(0.1)

      state[:response_data], = socket.recvfrom(1024)
      @retransmission_manager.handle_response(message.message_id, state[:response_data])
      state[:response_received] = true
    rescue StandardError => e
      update_state(state, nil, e.message)
    end

    def update_state(state, response_data, error)
      state[:response_data] = response_data
      state[:error] = error
      state[:response_received] = true
    end

    def handle_response_state(state, &callback)
      if state[:response_received] && !state[:error]
        deliver_response(state[:response_data], &callback)
      elsif state[:error]
        puts "TakagiClient Error: #{state[:error]}"
      else
        puts 'TakagiClient Error: Request timeout'
      end
    end

    def deliver_raw_response(response, &callback)
      if callback
        callback.call(response)
      elsif @callbacks[:response]
        @callbacks[:response].call(response)
      else
        puts response
      end
    end
  end
end
