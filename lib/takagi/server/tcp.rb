# frozen_string_literal: true

require 'socket'
require_relative '../response_builder'

module Takagi
  module Server
    # TCP server implementation for CoAP over TCP
    class Tcp # rubocop:disable Metrics/ClassLength -- pre-existing class size; splitting it is a separate refactor
      def initialize(port: 5683,
                     middleware_stack: nil, router: nil, logger: nil, watcher: nil, sender: nil,
                     max_connections: nil)
        @port = port
        @max_connections = max_connections
        @active_connections = 0
        @connections_mutex = Mutex.new
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
            if @shutdown_called || @shutdown_requested
              @logger.debug "TCP server accept loop stopped: #{e.message}"
            else
              @logger.error "TCP server accept failed: #{e.class}: #{e.message}"
            end
            break
          end

          unless track_connection
            @logger.warn "TCP connection limit (#{@max_connections}) reached; refusing new connection"
            client.close
            next
          end

          @logger.debug "Spawning handler thread for client"
          Thread.new(client) do |sock|
            begin
              handle_connection(sock)
            rescue => e
              @logger.error "Handler thread crashed: #{e.class}: #{e.message}"
              @logger.debug e.backtrace.join("\n")
            ensure
              release_connection
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

      def track_connection
        return true unless @max_connections

        @connections_mutex.synchronize do
          return false if @active_connections >= @max_connections

          @active_connections += 1
          true
        end
      end

      def release_connection
        return unless @max_connections

        @connections_mutex.synchronize { @active_connections -= 1 if @active_connections.positive? }
      end

      def handle_connection(sock)
        # RFC 8323 §3.3: the server's CSM is its first frame, before it reads anything
        send_csm(sock)

        loop do
          inbound_request = read_request(sock)
          break unless inbound_request

          @logger.debug "Received request from client: #{inbound_request.inspect}"

          case signaling_action(sock, inbound_request)
          when :ignore then next
          when :close then break
          end

          # Process regular CoAP requests
          transmit_response(sock, build_response(inbound_request))
        end
        @logger.debug "Client connection closed gracefully"
      rescue StandardError => e
        @logger.error "TCP handle_connection failed: #{e.message}"
        @logger.debug e.backtrace.join("\n")
      ensure
        sock.close unless sock.closed?
      end

      # Read request using RFC 8323 §3.2 variable-length framing
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
      # RFC 8323 §5.3
      def send_csm(sock)
        csm = build_csm_message
        # NEW: to_bytes now returns fully framed data
        framed = csm.to_bytes(transport: :tcp)
        written = sock.write(framed)
        sock.flush
        @logger.debug "Sent CSM to client (#{framed.bytesize} bytes, wrote #{written} bytes)"
      end

      # Classify an inbound frame's signalling code: :ignore drops it, :close ends the
      # connection, and nil marks a regular CoAP request to process.
      def signaling_action(sock, inbound_request)
        return :close if abort_on_critical_signalling_option?(sock, inbound_request)

        case inbound_request.code
        when CoAP::Registries::Method::EMPTY, CoAP::Registries::Signaling::PONG
          # RFC 8323 §5.4: an Empty message MUST be ignored; an unsolicited Pong has no reply.
          @logger.debug "Ignoring #{inbound_request.code.zero? ? 'Empty message' : 'unsolicited PONG'} from client"
          :ignore
        when CoAP::Registries::Signaling::CSM
          @logger.debug 'Received CSM from client'
          :ignore
        when CoAP::Registries::Signaling::PING
          @logger.debug 'Received PING from client'
          ping_action(sock, inbound_request)
        when CoAP::Registries::Signaling::RELEASE, CoAP::Registries::Signaling::ABORT
          @logger.debug "Received #{Takagi::CoAP::Registries::Signaling.name_for(inbound_request.code)} from client, closing connection"
          :close
        else
          # RFC 8323 §5.1 leaves unassigned 7.xx codes without a receiver rule; ignore for forward compatibility.
          if unassigned_signaling?(inbound_request.code)
            @logger.debug "Ignoring unassigned signalling code #{inbound_request.code}"
            :ignore
          end
        end
      end

      # RFC 8323 §5.4: a Ping is answered with a Pong carrying the identical Token.
      def ping_action(sock, inbound_request)
        send_pong(sock, inbound_request)
        :ignore
      end

      # RFC 8323 §5.2: a signalling option that is critical (an odd Option Number) and
      # not understood MUST abort the connection - for every signalling message, not
      # only for a Ping. §5.1 puts every 7.00-7.31 code in the signalling range, so CSM,
      # Ping, Pong, Release, Abort and an unassigned 7.xx are all covered; a regular CoAP
      # request is outside that range and keeps its own RFC 7252 §5.4.1 rule (4.02 Bad
      # Option), never a connection abort. Returns true when it aborted the connection.
      def abort_on_critical_signalling_option?(sock, inbound_request)
        return false unless signaling_range?(inbound_request.code) && inbound_request.options.keys.any?(&:odd?)

        name = CoAP::Registries::Signaling.name_for(inbound_request.code) ||
               "unassigned signalling code #{inbound_request.code}"
        @logger.debug "#{name} carries an unknown critical signalling option; aborting connection"
        send_abort(sock)
        true
      end

      # RFC 8323 §5.1: a code in the 7.00-7.31 range indicates a signalling message.
      def signaling_range?(code)
        code.between?(224, 255)
      end

      def unassigned_signaling?(code)
        signaling_range?(code) && !CoAP::Registries::Signaling.registered?(code)
      end

      def send_abort(sock)
        abort = Takagi::Message::Outbound.new(
          code: CoAP::Registries::Signaling::ABORT,
          payload: 'unknown critical signalling option',
          token: '',
          message_id: 0,
          type: 0,
          options: {},
          transport: :tcp
        )

        framed = abort.to_bytes(transport: :tcp)
        written = sock.write(framed)
        sock.flush
        @logger.debug "Sent ABORT to client (#{framed.bytesize} bytes, wrote #{written} bytes)"
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

      # Build CSM message with server capabilities
      # RFC 8323 §5.3
      def build_csm_message
        # CSM code is 7.01 (225)
        # Options: Max-Message-Size (2) only.
        # Block-Wise-Transfer (4) MUST NOT be advertised: block-wise transfer over
        # TCP requires RFC 8323 BERT handling, which is explicitly out of scope for
        # this server, so claiming the capability would be false.
        options = {
          2 => [8_388_864] # Max-Message-Size: 8MB
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
    end # rubocop:enable Metrics/ClassLength
  end
end
