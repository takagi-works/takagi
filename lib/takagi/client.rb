# frozen_string_literal: true

require 'socket'
require_relative 'network/udp_socket'
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
    def_delegators :@impl, :get, :post, :put, :delete, :on, :observe, :raw_exchange
    def_delegators :@impl, :ping
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
    def initialize(server_uri, timeout: 5, protocol: nil, use_retransmission: true,
                   recv_buffer_size: UdpClient::DEFAULT_RECV_BUFFER_SIZE)
      # Detect protocol from URI if not explicitly specified
      @protocol = protocol || detect_protocol(server_uri)

      # Delegate to the appropriate client implementation
      @impl = create_client_impl(server_uri, timeout, use_retransmission, recv_buffer_size)

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
    # @param use_retransmission [Boolean] Enable retransmission for UDP
    # @param recv_buffer_size [Integer] Maximum datagram size to receive
    # @return [UdpClient, TcpClient] The client implementation
    def create_client_impl(server_uri, timeout, use_retransmission,
                           recv_buffer_size = UdpClient::DEFAULT_RECV_BUFFER_SIZE)
      # Normalize URI to include scheme if not present
      normalized_uri = normalize_uri(server_uri)

      case @protocol
      when :tcp
        require_relative 'tcp_client'
        TcpClient.new(normalized_uri, timeout: timeout)
      when :udp
        UdpClient.new(
          normalized_uri,
          timeout: timeout,
          use_retransmission: use_retransmission,
          recv_buffer_size: recv_buffer_size
        )
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
    DEFAULT_RECV_BUFFER_SIZE = 65_535

    # Initializes the UDP client
    # @param server_uri [String] URL of the Takagi server
    # @param timeout [Integer] Maximum time to wait for a response
    # @param use_retransmission [Boolean] Enable RFC 7252 §4.2 compliant retransmission (default: true)
    # @param recv_buffer_size [Integer] Maximum datagram size to receive (default: 65_535)
    def initialize(server_uri, timeout: 5, use_retransmission: true, recv_buffer_size: DEFAULT_RECV_BUFFER_SIZE)
      super(server_uri, timeout: timeout)
      @use_retransmission = use_retransmission
      @recv_buffer_size = recv_buffer_size

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

    # UDP sends one datagram per message, so RFC 7959 block-wise iteration applies in
    # both directions here (see {ClientBlockWiseIteration}).
    #
    # @return [Boolean]
    def block_wise_transport?
      true
    end

    # Builds a UDP CoAP request message (RFC 7252).
    #
    # @param method [Symbol] HTTP method
    # @param uri [URI] Absolute request URI
    # @param payload [String, nil] Request body
    # @param token [String] Request token
    # @param options [Hash] CoAP options
    # @param type [Integer, nil] CoAP message type
    # @return [Takagi::Message::Request]
    def build_request_message(method, uri, payload, token:, options: {}, type: nil)
      Takagi::Message::Request.new(method: method, uri: uri, payload: payload, token: token, type: type, options: options)
    end

    # Sends one request and returns its raw response, retransmitting when enabled.
    #
    # @param message [Takagi::Message::Request] Message to send
    # @param uri [URI] Destination URI
    # @return [String, nil] raw response bytes, or nil on timeout/transport error
    def exchange(message, uri)
      return exchange_with_retransmission(message, uri) if @use_retransmission

      exchange_simple(message, uri)
    end

    # Sends a CoAP ping - an Empty Confirmable message - and reports whether the peer
    # answered with the Reset that elicits (RFC 7252 1.2, Table 1).
    #
    # The probe travels on its own socket under its own Message ID, so it can neither
    # collide with a request in flight nor consume one, and the socket is always closed.
    #
    # @return [Boolean] true when a Reset carrying the probe's Message ID arrives
    def transport_ping
      socket = Takagi::Network::UdpSocket.for(server_uri.hostname)
      message = build_ping_message
      socket.send(message.to_bytes, 0, server_uri.hostname, server_uri.port || 5683)

      read_ping_reset(socket, message.message_id)
    rescue StandardError => e
      Takagi.logger.debug "TakagiClient ping error: #{e.message}"
      false
    ensure
      socket&.close unless socket&.closed?
    end

    private

    # One datagram exchange without retransmission (legacy mode).
    #
    # An Empty Acknowledgement of the request is not its answer (RFC 7252 §5.2.2), so
    # {#read_answer} spends the rest of the timeout waiting for the response that follows.
    #
    # @param message [Takagi::Message::Request] Message to send
    # @param uri [URI] Destination URI
    # @return [String, nil] raw response bytes, or nil on timeout/transport error
    def exchange_simple(message, uri)
      socket = Takagi::Network::UdpSocket.for(uri.hostname)
      socket.send(message.to_bytes, 0, uri.hostname, uri.port || 5683)

      read_answer(socket, message)
    rescue StandardError => e
      Takagi.logger.error "TakagiClient error: #{e.message}"
      nil
    ensure
      socket&.close unless socket&.closed?
    end

    def read_answer(socket, message)
      deadline = Time.now + @timeout
      remaining = @timeout
      loop do
        return timed_out unless socket.wait_readable(remaining)

        response = read_datagram(socket)
        return response if response.nil? || !empty_acknowledgement?(response, message)

        remaining = deadline - Time.now
        return timed_out unless remaining.positive?
      end
    end

    # RFC 7252 §4.2 compliant exchange with automatic retransmission.
    #
    # @param message [Takagi::Message::Request] Message to send
    # @param uri [URI] Destination URI
    # @return [String, nil] raw response bytes, or nil on timeout/transport error
    def exchange_with_retransmission(message, uri)
      socket = Takagi::Network::UdpSocket.for(uri.hostname)
      state = send_with_retransmission(message, socket, uri)
      socket.close
      return state[:response_data] if state[:response_received] && !state[:error]
      return timed_out unless state[:error]

      Takagi.logger.error "TakagiClient error: #{state[:error]}"
      nil
    end

    # Reads one response datagram, warning when it fills the whole receive buffer.
    #
    # @param socket [UDPSocket] Socket to read from
    # @return [String, nil] raw response bytes, or nil when the datagram was truncated
    def read_datagram(socket)
      response, = socket.recvfrom(@recv_buffer_size)
      if response.bytesize >= @recv_buffer_size
        Takagi.logger.warn "TakagiClient response may be truncated (#{response.bytesize} bytes into a #{@recv_buffer_size}-byte buffer)"
        return nil
      end

      response
    end

    # Logs the shared timeout warning.
    #
    # @return [nil]
    def timed_out
      Takagi.logger.warn 'TakagiClient request timed out'
      nil
    end

    def send_with_retransmission(message, socket, uri)
      state = { response_received: false, response_data: nil, error: nil }

      @retransmission_manager.send_confirmable(
        message.message_id, message.to_bytes, socket, uri.hostname, uri.port || 5683
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

      state[:response_data], = socket.recvfrom(@recv_buffer_size)
      if state[:response_data].bytesize >= @recv_buffer_size
        update_state(state, nil, "response datagram may be truncated (#{state[:response_data].bytesize} bytes)")
        return
      end

      @retransmission_manager.handle_response(message.message_id, state[:response_data])
      state[:response_received] = true unless empty_acknowledgement?(state[:response_data], message)
    rescue StandardError => e
      update_state(state, nil, e.message)
    end

    def update_state(state, response_data, error)
      state[:response_data] = response_data
      state[:error] = error
      state[:response_received] = true
    end

    # Builds the UDP liveness probe: an Empty Confirmable message (RFC 7252 1.2/
    # Table 1). Its Message ID is drawn fresh so it never repeats a request's.
    #
    # @return [Takagi::Message::Outbound]
    def build_ping_message
      Takagi::Message::Outbound.new(
        code: '0.00', payload: '', token: ''.b,
        message_id: SecureRandom.random_number(0x1_0000),
        type: CoAP::Registries::MessageType::CON
      )
    end

    # Waits out the probe's timeout for a Reset echoing `message_id`.
    #
    # @param socket [UDPSocket] the socket the probe went out on
    # @param message_id [Integer] the probe's Message ID
    # @return [Boolean]
    def read_ping_reset(socket, message_id)
      deadline = Time.now + @timeout
      loop do
        remaining = deadline - Time.now
        return false unless remaining.positive? && socket.wait_readable(remaining)

        datagram, = socket.recvfrom(@recv_buffer_size)
        return true if reset_for?(datagram, message_id)
      end
    end

    # Whether a datagram is the Reset answering a ping with `message_id`.
    #
    # @param datagram [String, nil] raw datagram
    # @param message_id [Integer] the probe's Message ID
    # @return [Boolean]
    def reset_for?(datagram, message_id)
      return false unless datagram.is_a?(String) && datagram.bytesize >= 4
      return false unless ((datagram.getbyte(0) >> 4) & 0b11) == CoAP::Registries::MessageType::RST

      datagram.byteslice(2, 2).unpack1('n') == message_id
    end

    def empty_acknowledgement?(data, message)
      return false unless data.is_a?(String) && data.bytesize >= 4
      return false unless ((data.getbyte(0) >> 4) & 0b11) == CoAP::Registries::MessageType::ACK
      return false unless data.getbyte(1).zero?

      data.byteslice(2, 2).unpack1('n') == message.message_id
    end
  end
end
