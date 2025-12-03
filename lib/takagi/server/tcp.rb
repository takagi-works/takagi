# frozen_string_literal: true

require 'socket'
require_relative '../response_builder'

module Takagi
  module Server
    # TCP server implementation for CoAP over TCP
    class Tcp
      def initialize(port: 5683, worker_threads: 2,
                     middleware_stack: nil, router: nil, logger: nil, watcher: nil, sender: nil)
        @port = port
        @worker_threads = worker_threads
        @middleware_stack = middleware_stack || Takagi::MiddlewareStack.instance
        @router = router || Takagi::Router.instance
        @logger = logger || Takagi.logger
        @watcher = watcher || Takagi::Observer::Watcher.new(interval: 1)

        Initializer.run!

        @server = TCPServer.new('0.0.0.0', @port)
        @sender = sender || Takagi::Network::TcpSender.instance
      end

      def run!
        Takagi::Hooks.emit(:server_starting, protocol: :tcp, port: @port)
        @logger.info "Starting Takagi TCP server on port #{@port}"
        @workers = []
        @watcher.start

        # Set flag instead of calling shutdown! directly from trap context
        # This avoids "can't be called from trap context" errors with logger
        trap('INT') { @shutdown_requested = true }

        loop do
          break if @shutdown_called || @shutdown_requested

          begin
            @logger.debug "Waiting for client connection..."
            client = @server.accept
            @logger.debug "Client connected from #{client.peeraddr.inspect}"
          rescue IOError, SystemCallError => e
            @logger.error "TCP server accept failed: #{e.class}: #{e.message}"
            @logger.debug "TCP server accept loop exiting: #{e.message}" if @shutdown_called
            break
          end

          @logger.debug "Spawning handler thread for client"
          Thread.new(client) do |sock|
            begin
              handle_connection(sock)
            rescue => e
              @logger.error "Handler thread crashed: #{e.class}: #{e.message}"
              @logger.debug e.backtrace.join("\n")
            end
          end
        end

        # Call shutdown if it was requested by signal
        shutdown! if @shutdown_requested

        @logger.info "TCP server stopped"
        Takagi::Hooks.emit(:server_stopped, protocol: :tcp, port: @port)
      end

      def shutdown!
        return if @shutdown_called

        @shutdown_called = true
        @watcher.stop
        @server.close if @server && !@server.closed?

        # Join the server thread if it was spawned
        if defined?(@server_thread) && @server_thread&.alive?
          @server_thread.join(5) # Wait up to 5 seconds
        end
      end

      private

      def handle_connection(sock)
        # RFC 8323 §5.3: Read client CSM first, then send server CSM
        csm_received = false

        loop do
          inbound_request = read_request(sock)
          break unless inbound_request

          @logger.debug "Received request from client: #{inbound_request.inspect}"

          case inbound_request.code
          when CoAP::Registries::Signaling::CSM
            @logger.debug "Received CSM from client"
            unless csm_received
              # Send our CSM in response to client's CSM
              send_csm(sock)
              csm_received = true
            end
            next
          when CoAP::Registries::Signaling::PING
            @logger.debug "Received PING from client"
            send_pong(sock, inbound_request)
            next
          when CoAP::Registries::Signaling::RELEASE, CoAP::Registries::Signaling::ABORT
            @logger.debug "Received #{Takagi::CoAP::Registries::Signaling.name_for(inbound_request.code)} from client, closing connection"
            break
          end

          # Process regular CoAP requests
          response = build_response(inbound_request)
          transmit_response(sock, response)
        end
        @logger.debug "Client connection closed gracefully"
      rescue StandardError => e
        @logger.error "TCP handle_connection failed: #{e.message}"
        @logger.debug e.backtrace.join("\n")
      ensure
        sock.close unless sock.closed?
      end

      # Read request using RFC 8323 §3.3 variable-length framing
      # Uses the new Network::Framing::Tcp module
      def read_request(sock)
        # NEW: Use transport framing module
        data = Takagi::Network::Framing::Tcp.read_from_socket(sock, logger: @logger)
        return nil unless data

        Takagi::Message::Inbound.new(data, transport: :tcp)
      rescue IOError, Errno::ECONNRESET => e
        @logger.debug "read_request: Socket error (#{e.class}: #{e.message})"
        nil
      end

      def build_response(inbound_request)
        # TCP already runs each connection in its own thread, so we don't need
        # to delegate to controller pools - just process synchronously.
        # Controller pools are primarily for UDP where we have fixed worker threads.
        result = @middleware_stack.call(inbound_request)
        ResponseBuilder.build(inbound_request, result, logger: @logger)
      end

      def transmit_response(sock, response)
        # NEW: to_bytes now returns fully framed data from transport registry
        framed = response.to_bytes(transport: :tcp)
        written = sock.write(framed)
        sock.flush
        @logger.debug "Sent #{framed.bytesize} bytes to client (wrote #{written} bytes)"
      end

      # Send CSM (Capabilities and Settings Message) to client
      # RFC 8323 §5.3.1
      def send_csm(sock)
        csm = build_csm_message
        # NEW: to_bytes now returns fully framed data
        framed = csm.to_bytes(transport: :tcp)
        written = sock.write(framed)
        sock.flush
        @logger.debug "Sent CSM to client (#{framed.bytesize} bytes, wrote #{written} bytes)"
      end

      def send_pong(sock, request)
        pong = Takagi::Message::Outbound.new(
          code: CoAP::Registries::Signaling::PONG,
          payload: '',
          token: request.token,
          message_id: 0,
          type: 0,
          options: {},
          transport: :tcp
        )

        # NEW: to_bytes now returns fully framed data
        framed = pong.to_bytes(transport: :tcp)
        written = sock.write(framed)
        sock.flush
        @logger.debug "Sent PONG to client (#{framed.bytesize} bytes, wrote #{written} bytes)"
      end

      # Encode TCP frame with RFC 8323 §3.3 variable-length encoding
      # The first byte of data has format: Len (upper 4 bits) | TKL (lower 4 bits)
      # We need to update the Len nibble and potentially add extension bytes
      # NOTE: The Length field counts only Options + Payload, NOT Code or Token
      #
      # DEPRECATED: Use Network::Framing::Tcp.encode instead
      def encode_tcp_frame(data)
        return ''.b if data.empty?

        @logger.debug "encode_tcp_frame: input data (#{data.bytesize} bytes): #{data.inspect}"

        # Extract TKL from first byte
        first_byte = data.getbyte(0)
        tkl = first_byte & 0x0F

        # RFC 8323 §3.3: Length = size of (Options + Payload)
        # data structure: first_byte(1) + code(1) + token(tkl) + options + payload
        # So: payload_length = total - 1 (first_byte) - 1 (code) - tkl (token)
        code_size = 1
        payload_length = [data.bytesize - 1 - code_size - tkl, 0].max

        @logger.debug "encode_tcp_frame: first_byte=0x#{first_byte.to_s(16)}, tkl=#{tkl}, payload_length=#{payload_length}"

        body = data.byteslice(1, data.bytesize - 1) || ''.b

        result =
          if payload_length <= 12
            new_first_byte = (payload_length << 4) | tkl
            @logger.debug "encode_tcp_frame: new_first_byte=0x#{new_first_byte.to_s(16)}"
            [new_first_byte].pack('C') + body
          elsif payload_length <= 268
            new_first_byte = (13 << 4) | tkl
            extension = payload_length - 13
            [new_first_byte, extension].pack('CC') + body
          elsif payload_length <= 65_804
            new_first_byte = (14 << 4) | tkl
            extension = payload_length - 269
            [new_first_byte].pack('C') + [extension].pack('n') + body
          else
            new_first_byte = (15 << 4) | tkl
            extension = payload_length - 65_805
            [new_first_byte].pack('C') + [extension].pack('N') + body
          end

        @logger.debug "encode_tcp_frame: output (#{result.bytesize} bytes): #{result.inspect}"
        result
      end

      # Build CSM message with server capabilities
      # RFC 8323 §5.3.1
      def build_csm_message
        # CSM code is 7.01 (225)
        # Options: Max-Message-Size (2), Block-Wise-Transfer (4)
        # Both are required for compatibility with coap-client-gnutls
        options = {
          2 => [8_388_864],  # Max-Message-Size: 8MB
          4 => ['']          # Block-Wise-Transfer supported (empty string for zero-length option)
        }
        Takagi::Message::Outbound.new(
          code: CoAP::Registries::Signaling::CSM,
          payload: '',
          token: '',
          message_id: 0,
          type: 0,  # No type field in TCP CoAP
          options: options,
          transport: :tcp
        )
      end
    end
  end
end
