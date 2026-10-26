# frozen_string_literal: true

require 'socket'
require 'timeout'
require_relative '../response_builder'
require_relative 'cluster'

module Takagi
  module Server
    # TCP server implementation for CoAP over TCP
    class Tcp # rubocop:disable Metrics/ClassLength -- pre-existing class size; splitting it is a separate refactor
      # How long a handler thread may take to finish the connection it owns once the server
      # is stopped, before it is signalled - a pool thread and, when no pool is configured
      # (the default shape), a connection thread `spawn_handler` started. Bounded on purpose:
      # shutdown must never wait on a client that keeps its connection open. This is the drain
      # deadline this transport DECLARES to the cluster (the adapter's `drain_deadline`), and it
      # bounds the WHOLE drain rather than one join: every join of the drain and any post-signal
      # join spend from this one deadline. It is strictly below Cluster::WORKER_TERM_TIMEOUT,
      # the master's batch TERM->KILL deadline - a relation Cluster#assert_drain_fits_the_batch
      # refuses to let a service violate. The drain itself runs from #stop_pool, which the
      # accept loop's ensure calls as the cluster's stop path ends that loop.
      POOL_JOIN_TIMEOUT = 1.0

      # The cluster that SUPERVISES this transport: the one built here, or - once a service
      # adopts this server through #supervised_by - the SERVICE's cluster, which is the one
      # that really forks and supervises the children of a multi-transport service. Reading it
      # through this accessor is what keeps `srv.cluster`/`srv.worker_pids` from pointing at a
      # replaced supervisor.
      attr_reader :cluster

      # The declaration this transport hands to the cluster supervising it: the already-bound
      # listener, the declared unit of work and the pool's own limits (the contract is
      # Server::Cluster::Adapter). Built ONCE per server and public, so a service can ask this
      # transport what it will serve without reaching into the object (Server::Multi does that).
      attr_reader :adapter

      # The port this server's OWN socket actually bound. `port: 0` lets the kernel choose, so the
      # socket is the only honest source: this is the reader every other surface (the boot
      # payloads, the boot log, the service surface) reports from.
      def bound_port
        @server.addr[1]
      end

      # The pids the cluster supervising this transport is currently tracking, by fork order; nil
      # when it serves in-process and forked nothing. For a multi-transport service this is the
      # SERVICE's cluster (see #cluster), so the list is the same one Multi#worker_pids reports.
      def worker_pids
        @cluster.worker_pids
      end

      # Adopts `cluster` as the supervisor of this transport and returns self. A service that fans
      # several transports out through ONE cluster calls this on each of them, so `#cluster` and
      # `#worker_pids` report the cluster that really supervises this transport and the serve loop
      # reads the stop flag AND the parent-death guard of that same cluster (the one that forked
      # it). #shutdown! keeps stopping only the cluster this server built: the service's cluster is
      # the service's to stop (Server::Multi#shutdown!), never one transport's.
      def supervised_by(cluster)
        @cluster = cluster
        self
      end

      # Starts what a serving process must start BEFORE the cluster forks: this transport's
      # watcher, which drives its work on a thread and therefore cannot be started in a child.
      # Called from #run! and, for a service, once per transport by Server::Multi in the process
      # that boots the service - a fan-out never calls #run!.
      def start_service_hooks!
        @watcher.start
      end

      # TCP server for CoAP over TCP.
      #
      # @param worker_processes [Integer] how many OS worker processes serve the
      #   inherited listening socket. 1 (the default) keeps the single-process shape -
      #   this process accepts and handles the connections and forks nothing. Above 1
      #   this process becomes the master: it binds once, forks that many children and
      #   SUPERVISES them, reaping a dead child and forking a replacement so the
      #   configured count is kept rather than silently shrinking behind a port that
      #   still answers. There is deliberately NO cap and no back-off: a child that
      #   crashes is respawned as often as it dies, which is Puma's policy too
      #   (`lib/puma/cluster.rb` `check_workers` respawns every check with no limit).
      #   A crash-looping deployment therefore stays loud - each death is logged with
      #   the replacement that followed it - instead of quietly running below
      #   capacity, and turning supervision off is a human decision (fix the child or
      #   configure fewer workers), never an automatic one. Only when EVERY child is
      #   gone at once does supervision end: the master runs `shutdown!` so a wholly
      #   failed server fails visibly instead of holding a port with nobody behind it.
      # @param max_connections [Integer, nil] accepted-connection cap PER WORKER, so the
      #   effective ceiling of one server is `workers x max_connections`: with
      #   `worker_processes: 3, max_connections: 10` up to 30 connections are served at
      #   once, and a worker refuses only the connection that arrives once ITS OWN cap is
      #   reached. The accounting runs where the connection is accepted and served - the
      #   in-process server, or a forked child - never in the master, and there is
      #   deliberately no cross-process counter: a shared one would need IPC and is
      #   out of scope, so this is a per-worker guarantee and never a global one.
      #   The queue-versus-refuse policy is part of the rule: a connection below this cap
      #   is accepted, and is QUEUED rather than refused when every handler thread is
      #   busy (`worker_threads`); only a connection that arrives once the cap is reached
      #   is refused, with the refusal warning and an immediate EOF to the client. nil
      #   (the default) keeps today's unlimited behaviour, and a single-process server is
      #   unchanged: `max_connections: 1` still refuses its second connection
      #   (`spec/unit/tcp_connection_limit_spec.rb`).
      # @param worker_threads [Integer, nil] how many handler threads serve accepted
      #   connections in THIS process. nil (the default) keeps today's
      #   thread-per-connection model, and so does a count at or above
      #   `max_connections`: neither can bound concurrency below what the
      #   accepted-connection cap already bounds, so no pool thread is started and the
      #   behaviour is byte for byte the one a deployment has today. Below the cap,
      #   that many threads pull accepted sockets from a queue and run the very same
      #   handler the thread-per-connection model runs; a connection that finds every
      #   thread busy waits in the queue rather than being refused, and a pool thread
      #   owns its connection for that connection's whole lifetime (there is no
      #   per-request multiplexing). The queue is therefore the backpressure, and the
      #   refusal policy is unchanged: a connection is refused, with the warning above,
      #   only when `max_connections` is reached. The pool is per serving process - the
      #   in-process server and every forked child build their own, after the fork.
      def initialize(port: 5683, worker_processes: 1, worker_threads: nil, # rubocop:disable Metrics/ParameterLists -- tcp-multi-worker rows 1,6 kw 8/9; refactor
                     middleware_stack: nil, router: nil, logger: nil, watcher: nil, sender: nil,
                     max_connections: nil, bind_address: '0.0.0.0')
        @port = port
        @worker_processes = worker_processes
        @worker_threads = worker_threads
        @pool = nil
        @pool_threads = nil
        @max_connections = max_connections
        @active_connections = 0
        @connections_mutex = Mutex.new
        # The connection threads a NON-pooled server starts: nothing joined them, so the stop
        # path has to know them. Empty - and never filled - when a pool serves the connections.
        @handler_threads = []
        @middleware_stack = middleware_stack || Takagi::MiddlewareStack.instance
        @router = router || Takagi::Router.instance
        @logger = logger || Takagi.logger
        @watcher = watcher || Takagi::Observer::Watcher.new(interval: 1)

        Initializer.run!

        @server = TCPServer.new(bind_address, @port)
        # port: 0 asks the kernel for a free port, so the port that was ACTUALLY bound
        # is the only truth downstream: the :server_starting/:server_stopped payloads,
        # the boot log and a worker's own log line all report this value. Verified
        # before the fix: the socket held 36981 while the payload and the boot log
        # both said 0, which is also why a test could not assert against either.
        @port = @server.addr[1]
        @sender = sender || Takagi::Network::TcpSender.instance
        # ONE declaration and ONE cluster built here: the service's cluster supervises this
        # transport through the same adapter once #supervised_by hands it over.
        @adapter = build_cluster_adapter
        @owned_cluster = Cluster.new(count: @worker_processes.to_i, adapters: [@adapter], logger: @logger)
        # `@cluster` is the cluster that SUPERVISES this transport: the one built here until a
        # service adopts the server (#supervised_by), the service's cluster afterwards.
        @cluster = @owned_cluster
      end

      def run!
        Takagi::Hooks.emit(:server_starting, protocol: :tcp, port: @port)
        @logger.info "Starting Takagi TCP server on port #{@port}"

        start_service_hooks!
        # The cluster owns the children, the supervision loop and the TERM/INT handling: at a
        # count of 1 it runs the accept loop in this process and forks nothing.
        @cluster.run!

        # The cluster returns only once it was stopped or its last child died; either way this
        # server's lifecycle ends here, LOUDLY in the second case.
        shutdown!

        @logger.info "TCP server stopped"
      end

      def shutdown!
        return if @shutdown_called

        @shutdown_called = true
        @watcher.stop
        # Before the cluster closes the listener: a pool thread owns the client socket it is
        # serving, which the listener's close cannot reach, so the pool is stopped here rather
        # than left to outlive the server. A master has no pool, so its call is a no-op.
        stop_pool
        # Children first, then this process's copies of the listeners (Cluster#shutdown!) - and
        # ONLY the cluster this server built. On a multi-transport service the supervisor is the
        # SERVICE's cluster (see #supervised_by), and stopping that is the service's business
        # (Multi#shutdown!): shutting one transport down stops THAT transport, never the service.
        @owned_cluster.shutdown!

        # Join the server thread if it was spawned
        if defined?(@server_thread) && @server_thread&.alive?
          @server_thread.join(5) # Wait up to 5 seconds
        end

        # Emitted exactly once per server, whether the supervisor returned on its own or a caller
        # stopped this transport directly. It used to be emitted at the end of #run!, which a
        # service fan-out never calls - so a working multi-transport service never saw TCP stop.
        Takagi::Hooks.emit(:server_stopped, protocol: :tcp, port: @port)
      end

      private

      # The declaration this transport makes to the cluster supervising it: the already-bound
      # listener, the declared unit of work and the pool's own limits. Built once in the constructor,
      # and #adapter is the reader a service asks through.
      def build_cluster_adapter
        Adapter.new(
          server: self,
          fds: [@server],
          unit_of_work: :connection,
          thread_count: @worker_threads,
          admission_cap: @max_connections,
          drain_deadline: POOL_JOIN_TIMEOUT
        )
      end

      # True once this serving process must stop accepting and handling connections. The
      # cluster's flag carries the parent-death guard in a child, so a worker whose master is
      # gone leaves on its own instead of holding an inherited socket.
      def stop_requested?
        @shutdown_called || @cluster.stopping?
      end

      # The adapter's stop hook: asks the cluster to stop, which is what the accept loop's
      # stop_requested? reads.
      def request_stop!
        @cluster.stop!
      end

      # Called by the cluster in the process that serves, after the fork: no pool thread,
      # handler thread or connection count is ever inherited across a fork.
      def prepare_serving_process
        @pool = nil
        @pool_threads = nil
        @handler_threads = []
        @active_connections = 0
      end

      def accept_loop
        start_pool
        loop do
          break if stop_requested?

          begin
            @logger.debug 'Waiting for client connection...'
            next unless @server.wait_readable(0.1)

            client = @server.accept_nonblock
            @logger.debug "Client connected from #{client.peeraddr.inspect}"
          rescue IO::WaitReadable, Errno::EINTR
            # Several workers share one listen queue, so another one may win the race.
            next
          rescue IOError, SystemCallError => e
            if stop_requested?
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

          spawn_handler(client)
        end
      ensure
        stop_pool
      end

      # A pooled server hands the accepted socket to a handler thread through the queue;
      # every other configuration keeps today's thread-per-connection spawn - and the thread
      # it starts is TRACKED, so the stop path can join it exactly as it joins a pool thread.
      # The handler body itself is the same either way.
      def spawn_handler(client)
        if @pool
          @logger.debug 'Queueing client connection for the handler pool'
          @pool << client
        else
          @logger.debug 'Spawning handler thread for client'
          track_handler_thread(Thread.new(client) { |sock| run_handler(sock) })
        end
      end

      # Remembers one connection thread of THIS process and forgets the ones that already
      # finished, so a long-lived server tracks its in-flight work without collecting dead
      # threads. Only the accept loop fills this list; the stop path takes the whole list
      # away in one swap, exactly as #stop_pool does with @pool_threads.
      def track_handler_thread(thread)
        @handler_threads.reject!(&:alive?)
        @handler_threads << thread
      end

      # The handler body, shared by both models: the connection's own thread runs it in
      # today's path, a pool thread runs it when a pool exists. Semantics are untouched -
      # CSM first, the signalling dispatch and the per-connection read/write loop.
      def run_handler(sock)
        handle_connection(sock)
      rescue StandardError => e
        @logger.error "Handler thread crashed: #{e.class}: #{e.message}"
        @logger.debug e.backtrace.join("\n")
      ensure
        release_connection
      end

      # The pool is built by the process that serves - the in-process server and a
      # forked child each start their own, after the fork - so no pool thread ever has
      # to survive a fork.
      def start_pool
        return unless pooled?

        pool = Queue.new
        @pool = pool
        @pool_threads = Array.new(@worker_threads.to_i) do |index|
          Thread.new do
            Thread.current.name = "takagi-tcp-pool-#{index}"
            pool_loop(pool)
          end
        end
        @logger.debug "TCP handler pool started with #{@pool_threads.size} threads"
      end

      # No handler thread outlives the server: poison pills end an idle worker, a
      # bounded join gives a busy one the pool's own deadline, and only a straggler
      # still holding a connection is signalled. Idempotent, because the accept loop's
      # ensure and `shutdown!` both call it. ONE deadline covers the whole drain - the
      # join and any post-signal join both spend from it - so the drain stays inside the
      # number this transport declared to the cluster instead of multiplying it per thread.
      # This is the stop path of BOTH shapes the transport can serve: with no pool (the
      # default `worker_threads` unset) it drains the connection threads instead.
      def stop_pool
        threads = @pool_threads
        pool = @pool
        @pool_threads = nil
        @pool = nil
        return drain_connections unless threads

        threads.size.times { pool << nil }
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + POOL_JOIN_TIMEOUT
        threads.each do |thread|
          thread.join(drain_budget(deadline))
          next unless thread.alive?

          thread.kill
          thread.join(drain_budget(deadline))
        end
      end

      # The non-pooled half of the same contract: every connection thread this process started
      # is joined against the deadline this transport DECLARED to the cluster - the adapter's
      # `drain_deadline`, which is the ONE value `POOL_JOIN_TIMEOUT` carries, never a second
      # number - and a straggler still holding its connection is signalled at that deadline
      # instead of being waited on. The accept loop has already left its loop when its ensure
      # calls this, so no new connection can be spawned into the drain; a `shutdown!` that lands
      # while the loop is still running leaves a later connection to the ensure's own call.
      def drain_connections
        threads = @handler_threads
        @handler_threads = []
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @adapter.drain_deadline
        threads.each do |thread|
          thread.join(drain_budget(deadline))
          next unless thread.alive?

          thread.kill
          thread.join(drain_budget(deadline))
        end
      end

      # What is left of the pool's ONE drain deadline. A join that would run past it is handed
      # 0 instead of a fresh timeout: the whole drain stays inside POOL_JOIN_TIMEOUT, the number
      # the cluster was promised, so the master's KILL can never catch a drain that is still
      # inside its declared contract.
      def drain_budget(deadline)
        left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        left.positive? ? left : 0
      end

      # One pool thread's loop: pop an accepted socket, run the same handler the
      # thread-per-connection model runs, and release the connection's accounting slot.
      def pool_loop(pool)
        loop do
          client = pool.pop
          break if client.nil?

          run_handler(client)
        end
      end

      # A pool bounds concurrency only when it can: an unset count and a count at or
      # above `max_connections` both keep today's thread-per-connection model, so no
      # existing deployment starts an extra thread.
      def pooled?
        return false if @worker_threads.nil?
        return true if @max_connections.nil?

        @worker_threads.to_i < @max_connections.to_i
      end

      # Accepted-connection accounting for THIS serving process, which is what makes
      # `max_connections` a per-worker cap: the in-process server and every forked child
      # each count their own connections, and the master counts none at all. A child
      # starts from zero because the master never accepts, so the count is per worker by
      # construction - no shared counter exists, and adding one would need IPC (out of
      # scope).
      def track_connection
        return true unless @max_connections

        @connections_mutex.synchronize do
          return false if @active_connections >= @max_connections

          @active_connections += 1
          true
        end
      end

      # Releases the slot taken by the process that SERVED the connection, so a worker's
      # capacity returns the moment its own connection ends and no other worker's does.
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
        # TCP runs each connection in its own thread (or the bounded handler pool), so it
        # processes synchronously. There is no controller pool to delegate to.
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

      # The cluster adapter for this transport: it declares the already-bound listener, the
      # serve loop and the connection-sized unit of work, and holds Method objects onto this
      # server's private serving surface. See Server::Cluster::Adapter for the contract every
      # transport implements; the cluster itself never names a transport.
      class Adapter
        include Cluster::Adapter

        def initialize(server:, fds:, unit_of_work:, thread_count:, admission_cap:, drain_deadline:)
          @fds = fds
          @unit_of_work = unit_of_work
          @thread_count = thread_count
          @admission_cap = admission_cap
          @drain_deadline = drain_deadline
          @serve = server.method(:accept_loop)
          @stop_requested = server.method(:stop_requested?)
          @stop = server.method(:request_stop!)
          @prepare = server.method(:prepare_serving_process)
        end

        attr_reader :fds, :unit_of_work, :thread_count, :admission_cap, :drain_deadline

        def serve_loop = @serve.call

        def stop_requested? = @stop_requested.call

        def stop! = @stop.call

        def prepare_process = @prepare.call
      end
    end # rubocop:enable Metrics/ClassLength
  end
end
