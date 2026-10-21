# frozen_string_literal: true

require 'socket'
require 'securerandom'
require_relative 'client_base'

module Takagi
  # CoAP-over-TCP client for testing Takagi servers with TCP transport.
  #
  # This client implements CoAP over TCP (RFC 8323) with automatic length framing.
  # Unlike the UDP client, TCP provides reliable delivery so no retransmission
  # manager is needed.
  #
  # @example Basic usage with auto-close (recommended)
  #   Takagi::TcpClient.open('coap+tcp://localhost:5683') do |client|
  #     client.get('/temperature')
  #   end
  #
  # @example Manual lifecycle management
  #   client = Takagi::TcpClient.new('coap+tcp://localhost:5683')
  #   begin
  #     client.get('/temperature')
  #   ensure
  #     client.close
  #   end
  class TcpClient < ClientBase
    # Frames the client reads while looking for a response before giving up: a peer that
    # only streams signalling frames must not be able to hold the exchange open.
    MAX_EXCHANGE_FRAMES = 4

    # Wraps the socket for one read pass so every read below the caller's deadline is
    # bounded by it. {Takagi::Network::Framing::Tcp.read_from_socket} blocks until the peer
    # closes once a frame's first bytes have arrived and the rest of it never does, so a
    # caller that only checks its deadline between frames still hangs on a stalled body:
    # this gates each read on `wait_readable(remaining)` and reports a deadline mid-frame
    # the way a closed socket reports end of stream, which the framer already handles as an
    # incomplete frame.
    class DeadlineSocket
      # @param io [IO] socket the framer reads from
      # @param deadline [Time] the one absolute deadline of the exchange
      def initialize(io, deadline)
        @io = io
        @deadline = deadline
      end

      # Reads exactly `length` bytes, or nil once the deadline passes.
      #
      # @param length [Integer] bytes to read
      # @return [String, nil]
      def read(length)
        data = +''.b
        while data.bytesize < length
          return nil unless wait_readable

          begin
            data << @io.readpartial(length - data.bytesize)
          rescue EOFError
            return nil
          end
        end
        data
      end

      # Reads what has arrived, raising EOFError at the deadline exactly as a closed
      # socket raises it at end of stream.
      #
      # @param length [Integer] maximum bytes to read
      # @return [String]
      def readpartial(length)
        raise EOFError, 'exchange deadline passed mid-frame' unless wait_readable

        @io.readpartial(length)
      end

      private

      # @return [Boolean] whether the wrapped socket has data before the deadline
      def wait_readable
        remaining = @deadline - Time.now
        remaining.positive? && @io.wait_readable(remaining)
      end
    end
    private_constant :DeadlineSocket

    protected

    # TCP framing carries a whole message in one frame, and Takagi deliberately does not
    # implement RFC 8323 block-wise transfer over TCP (the TCP server's CSM says as much),
    # so requests over this transport are exchanged as a single round trip - the frames
    # around it (a CSM each way) are signalling, not part of the round trip.
    #
    # @return [Boolean]
    def block_wise_transport?
      false
    end

    # Responses arrive length-framed (RFC 8323 §3.2), not in datagrams.
    #
    # @return [Symbol]
    def response_transport
      :tcp
    end

    # Builds a CoAP-over-TCP request message (RFC 8323).
    #
    # @param method [Symbol] HTTP method
    # @param uri [URI] Absolute request URI
    # @param payload [String, Hash, nil] Request body
    # @param token [String] Request token
    # @param options [Hash] CoAP options { option_number => value }
    # @param type [Integer, nil] CoAP message type
    # @return [Takagi::Message::Outbound]
    def build_request_message(method, uri, payload, token:, options: {}, type: nil)
      Takagi::Message::Outbound.new(
        code: CoAP::CodeHelpers.to_numeric(method),
        payload: payload,
        token: token,
        type: type || CoAP::Registries::MessageType::CON,
        options: combined_options(uri, options),
        transport: :tcp
      )
    end

    # Merges the caller's options with the URI's path and query segments.
    #
    # @param uri [URI] Request URI
    # @param options [Hash] Caller-supplied CoAP options
    # @return [Hash] options including Uri-Path and Uri-Query
    def combined_options(uri, options)
      combined = (options || {}).dup
      add_uri_path(combined, uri.path)
      add_uri_query(combined, uri.query)
      combined
    end

    # Appends the Uri-Path segments of a path to the option set.
    #
    # @param combined [Hash] options being built
    # @param path [String] URI path
    # @return [void]
    def add_uri_path(combined, path)
      segments = path.to_s.split('/').reject(&:empty?)
      return if segments.empty?

      combined[CoAP::Registries::Option::URI_PATH] ||= []
      segments.each { |segment| combined[CoAP::Registries::Option::URI_PATH] << segment }
    end

    # Appends the Uri-Query segments of a query string to the option set.
    #
    # @param combined [Hash] options being built
    # @param query [String, nil] URI query
    # @return [void]
    def add_uri_query(combined, query)
      return if query.nil? || query.empty?

      combined[CoAP::Registries::Option::URI_QUERY] ||= []
      query.split('&').each { |segment| combined[CoAP::Registries::Option::URI_QUERY] << segment }
    end

    # Opens a connection, sends one message and returns the raw response.
    #
    # @param message [Takagi::Message::Outbound] Message to send
    # @param uri [URI] Destination URI
    # @return [String, nil] raw framed response, or nil on transport error
    def exchange(message, uri)
      socket = TCPSocket.new(uri.hostname, uri.port || 5683)
      socket.write(build_csm_message.to_bytes(transport: :tcp))
      socket.write(message.to_bytes(transport: :tcp))

      read_response_frame(socket)
    rescue StandardError => e
      Takagi.logger.error "TakagiTcpClient Error: #{e.message}"
      nil
    ensure
      socket&.close unless socket&.closed?
    end

    # Builds the client's Capabilities and Settings Message (RFC 8323 §3.3): the first
    # frame it sends, advertising only Max-Message-Size.
    #
    # @return [Takagi::Message::Outbound]
    def build_csm_message
      Takagi::Message::Outbound.new(
        code: CoAP::Registries::Signaling::CSM,
        payload: '',
        token: '',
        message_id: 0,
        type: 0,
        options: { 2 => [8_388_864] },
        transport: :tcp
      )
    end

    # Reads frames until a non-signalling one arrives, skipping the peer's handshake
    # (RFC 8323 §3.3/§5), and gives up after {MAX_EXCHANGE_FRAMES} frames or the client's
    # own timeout. The timeout is one deadline for the whole read: it is checked before each
    # frame and, through {DeadlineSocket}, before each read inside a frame, so a peer that
    # announces an in-range body and then stalls is released by the deadline instead of by
    # its own close.
    #
    # @param socket [TCPSocket] connected socket
    # @return [String, nil] raw framed response, or nil when none arrives in time
    def read_response_frame(socket)
      deadline = Time.now + timeout
      bounded = DeadlineSocket.new(socket, deadline)
      MAX_EXCHANGE_FRAMES.times do
        remaining = deadline - Time.now
        return nil if remaining <= 0 || !socket.wait_readable(remaining)

        frame = Takagi::Network::Framing::Tcp.read_from_socket(bounded)
        return nil if frame.nil?

        inbound = Takagi::Network::Framing::Tcp.decode(frame)
        return frame unless CoAP::Registries::Signaling.signaling?(inbound.code)
      end
      nil
    end

    # Sends a CoAP-over-TCP Ping and reports whether a Pong carrying the same token
    # answers it (RFC 8323 5.4).
    #
    # The probe opens its own connection, writes this transport's one CSM as the first
    # frame exactly as {#exchange} does, and then the Ping; the peer's own signalling
    # frames are skipped while looking for the Pong. The socket is always closed.
    #
    # @return [Boolean] true when a Pong with the probe's token arrives in time
    def transport_ping
      socket = TCPSocket.new(server_uri.hostname, server_uri.port || 5683)
      token = SecureRandom.hex(4)
      socket.write(build_csm_message.to_bytes(transport: :tcp))
      socket.write(ping_message(token).to_bytes(transport: :tcp))

      pong_for?(socket, token)
    rescue StandardError => e
      Takagi.logger.debug "TakagiTcpClient ping error: #{e.message}"
      false
    ensure
      socket&.close unless socket&.closed?
    end

    # Builds the TCP liveness probe: a Ping signalling message (RFC 8323 5.4).
    #
    # @param token [String] fresh token identifying this probe
    # @return [Takagi::Message::Outbound]
    def ping_message(token)
      Takagi::Message::Outbound.new(
        code: CoAP::Registries::Signaling::PING,
        payload: '', token: token, message_id: 0, type: 0, transport: :tcp
      )
    end

    # Reads frames until a Pong carrying `token` arrives, skipping the peer's handshake,
    # and gives up after {MAX_EXCHANGE_FRAMES} frames or the client's timeout.
    #
    # @param socket [TCPSocket] the connection the probe went out on
    # @param token [String] the probe's token
    # @return [Boolean]
    def pong_for?(socket, token)
      deadline = Time.now + timeout
      bounded = DeadlineSocket.new(socket, deadline)
      MAX_EXCHANGE_FRAMES.times do
        remaining = deadline - Time.now
        return false if remaining <= 0 || !socket.wait_readable(remaining)

        frame = Takagi::Network::Framing::Tcp.read_from_socket(bounded)
        return false if frame.nil?

        inbound = Takagi::Network::Framing::Tcp.decode(frame)
        return true if inbound.code == CoAP::Registries::Signaling::PONG && inbound.token == token
      end
      false
    end
  end
end
