# frozen_string_literal: true

require 'socket'
require 'timeout'
require_relative 'cluster'
require_relative 'udp_worker'
require_relative '../network/udp_socket'

module Takagi
  module Server
    # UDP server for handling CoAP messages
    class Udp
      # How long in-flight datagram work may take to finish once this transport is stopped:
      # the value this adapter declares to the cluster as its #drain_deadline, and the same
      # value the worker enforces when its receive loop ends (UdpWorker::DRAIN_DEADLINE is the
      # single source, so the declaration and the join cannot drift). It is strictly below
      # Cluster::WORKER_TERM_TIMEOUT (2.0 s), the master's batch TERM->KILL deadline - a
      # relation Cluster#assert_drain_fits_the_batch refuses to let a service violate - so a
      # child always drains inside the deadline its master allows, the same relation TCP
      # states with its POOL_JOIN_TIMEOUT.
      DRAIN_DEADLINE = UdpWorker::DRAIN_DEADLINE

      # The cluster that SUPERVISES this transport: the one built here, or - once a service
      # adopts this server through #supervised_by - the SERVICE's cluster, which is the one
      # that really forks and supervises the children of a multi-transport service. Reading it
      # through this accessor is what keeps `srv.cluster`/`srv.worker_pids` from pointing at a
      # replaced supervisor.
      attr_reader :cluster

      # The declaration this transport hands to the cluster supervising it: the already-bound
      # socket, the declared unit of work and this transport's thread count (the contract is
      # Server::Cluster::Adapter). Built ONCE per server and public, so a service can ask this
      # transport what it will serve without reaching into the object (Server::Multi does that).
      attr_reader :adapter

      # The port this server's OWN socket actually bound. `port: 0` lets the kernel choose, so the
      # socket is the only honest source: this is the reader every other surface (the boot
      # payloads, the boot log, the service surface) reports from.
      def bound_port
        @socket.addr[1]
      end

      # The pids the cluster supervising this transport is currently tracking, by fork order; nil
      # when it serves in-process and forked nothing. For a multi-transport service this is the
      # SERVICE's cluster (see #cluster), so the list is the same one Multi#worker_pids reports.
      def worker_pids
        @cluster.worker_pids
      end

      # Adopts `cluster` as the supervisor of this transport and returns self. A service that fans
      # several transports out through ONE cluster calls this on each of them, so `#cluster` and
      # `#worker_pids` report the cluster that really supervises this transport and the datagram
      # serve loop reads the stop flag AND the parent-death guard of that same cluster (the one
      # that forked it). #shutdown! keeps stopping only the cluster this server built: the
      # service's cluster is the service's to stop (Server::Multi#shutdown!), never one transport's.
      def supervised_by(cluster)
        @cluster = cluster
        self
      end

      # Starts what a serving process must start BEFORE the cluster forks: the reactors and this
      # transport's watcher, which drive their work on threads and therefore cannot be started in
      # a child. Called from #run! and, for a service, once per transport by Server::Multi in the
      # process that boots the service - a fan-out never calls #run!.
      def start_service_hooks!
        Takagi::Observable::Registry.start_all
        @watcher.start
      end

      def initialize(port: 5683, worker_processes: 2, worker_threads: 2, # rubocop:disable Metrics/ParameterLists -- same transport-config list tcp.rb carries; refactor together
                     middleware_stack: nil, router: nil, logger: nil, watcher: nil,
                     bind_address: '0.0.0.0')
        @port = port
        @bind_address = bind_address
        @worker_processes = worker_processes
        @worker_threads = worker_threads
        @middleware_stack = middleware_stack || Takagi::MiddlewareStack.instance
        @router = router || Takagi::Router.instance
        @logger = logger || Takagi.logger
        @watcher = watcher || Takagi::Observer::Watcher.new(interval: 1)

        Initializer.run!

        # The socket's family follows the address: `UDPSocket.new` alone is AF_INET, which cannot
        # bind an IPv6 address at all (see Takagi::Network::UdpSocket).
        @socket = Takagi::Network::UdpSocket.for(@bind_address)
        @socket.bind(@bind_address, @port)
        # port: 0 asks the kernel for a free port, so the port that was ACTUALLY bound is the only
        # truth downstream: the :server_starting/:server_stopped payloads and the worker's own log
        # line all report this value, exactly as tcp.rb does.
        @port = @socket.addr[1]
        Takagi::Network::UdpSender.instance.setup(socket: @socket)
        @sender = Takagi::Network::UdpSender.instance
        # ONE declaration and ONE cluster built here: the service's cluster supervises this
        # transport through the same adapter once #supervised_by hands it over.
        @adapter = build_cluster_adapter
        @owned_cluster = Cluster.new(count: @worker_processes.to_i, adapters: [@adapter], logger: @logger)
        # `@cluster` is the cluster that SUPERVISES this transport: the one built here until a
        # service adopts the server (#supervised_by), the service's cluster afterwards.
        @cluster = @owned_cluster
      end

      # Starts the server. The cluster owns the fork, the supervision and the ordered
      # shutdown: at a count of 1 this process runs the datagram loop itself and forks
      # nothing, and above 1 this process becomes the master of `count` children titled
      # `takagi-worker-<index>`, reaping and replacing each one that dies.
      def run!
        Takagi::Hooks.emit(:server_starting, protocol: :udp, port: @port)
        log_boot_details
        # Started in the MASTER, before the cluster forks. The watcher and the reactors drive
        # their work on threads, and threads do not survive a fork: a child inherits their
        # started flags and no worker ever re-starts them, so the datagram path in a child
        # stays synchronous (Server::UdpWorker#delegate_to_controller_pool).
        start_service_hooks!

        @cluster.run!

        shutdown!
      end

      # Gracefully shuts down all workers
      def shutdown!
        return if @shutdown_called

        @shutdown_called = true
        @watcher.stop
        # Children first, then this process's own copy of the listening socket, in that
        # order (Cluster#shutdown!) - and ONLY the cluster this server built. On a multi-transport
        # service the supervisor is the SERVICE's cluster (see #supervised_by), and stopping that
        # is the service's business (Multi#shutdown!): shutting one transport down stops THAT
        # transport, never the service.
        @owned_cluster.shutdown!
        close_socket
        Takagi::Observable::Registry.stop_all

        # Join the server thread if it was spawned
        if defined?(@server_thread) && @server_thread&.alive?
          @server_thread.join(5) # Wait up to 5 seconds
        end

        Takagi::Hooks.emit(:server_stopped, protocol: :udp, port: @port)
      end

      private

      def log_boot_details
        @logger.info "Starting Takagi server with #{@worker_processes} processes and #{@worker_threads} threads per process..."
        @logger.info "Takagi server has version #{Takagi::VERSION} with name '#{Takagi::NAME}'"
        @logger.debug "run #{@router.all_routes}"
      end

      # The declaration this transport makes to the cluster supervising it: the ALREADY-BOUND
      # socket (nothing is bound here, and no second bind or SO_REUSEPORT is ever set: the
      # children inherit this fd), the declared unit of work and this transport's thread count.
      # Built once in the constructor, and #adapter is the reader a service asks through.
      def build_cluster_adapter
        Adapter.new(
          server: self,
          fds: [@socket],
          unit_of_work: :datagram,
          thread_count: @worker_threads,
          admission_cap: nil,
          drain_deadline: DRAIN_DEADLINE
        )
      end

      # True once this serving process must stop its datagram loop. The cluster's flag carries
      # the parent-death guard in a child, armed with the master pid it captured BEFORE the
      # fork, so a worker whose master is gone leaves on its own instead of serving forever on
      # the inherited socket.
      def stop_requested?
        @shutdown_called || @cluster.stopping?
      end

      # The adapter's stop hook: asks the cluster to stop, which is what the serve loop's
      # stop_requested? reads.
      def request_stop!
        @cluster.stop!
      end

      # Called by the cluster in the process that serves, right after the fork and before
      # #serve_datagrams. The worker, its reader threads and its dedup cache are all built by
      # #serve_datagrams IN the serving process, so there is no inherited per-process state to
      # reset here; the hook exists because every adapter implements it.
      def prepare_serving_process; end

      # The serve loop the cluster runs once per serving process: today's UdpWorker#run,
      # driven by this server's stop state rather than by a parent pid it reads for itself. The
      # loop's own end IS the stop path's drain: the worker handles the datagrams already
      # received and joins its reader threads inside DRAIN_DEADLINE (UdpWorker#drain) before it
      # returns here, so nothing is left for the socket's close to race.
      def serve_datagrams
        build_worker.run
      end

      def build_worker
        UdpWorker.new(**worker_configuration, stop_requested: method(:stop_requested?))
      end

      def worker_configuration
        {
          port: @port,
          bind_address: @bind_address,
          socket: @socket,
          middleware_stack: @middleware_stack,
          router: @router,
          sender: @sender,
          logger: @logger,
          threads: @worker_threads,
          drain_deadline: DRAIN_DEADLINE
        }
      end

      def close_socket
        return unless @socket && !@socket.closed?

        @socket.close
      rescue IOError, SystemCallError
        nil
      end

      # The cluster adapter for this transport: it declares the already-bound socket, the
      # datagram serve loop and the datagram-sized unit of work, and holds Method objects onto
      # this server's private serving surface. See Server::Cluster::Adapter for the contract
      # every transport implements; the cluster itself never names a transport.
      class Adapter
        include Cluster::Adapter

        def initialize(server:, fds:, unit_of_work:, thread_count:, admission_cap:, drain_deadline:)
          @fds = fds
          @unit_of_work = unit_of_work
          @thread_count = thread_count
          @admission_cap = admission_cap
          @drain_deadline = drain_deadline
          @serve = server.method(:serve_datagrams)
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
    end
  end
end
