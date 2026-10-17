# frozen_string_literal: true

require_relative 'cluster'

module Takagi
  module Server
    # Runs a service's transports concurrently, delegating the fan-out: this class implements
    # none of its own.
    #
    # Every transport's adapter is handed to ONE {Server::Cluster} and both #run! and #shutdown!
    # delegate to it, so the cluster owns the threads at a count of 1 and the children above it -
    # one implementation of "serve several transports at once" instead of two. What stays here is
    # only what the cluster cannot know, because it never names a transport: the per-transport
    # `:server_starting` payloads (with the port each transport's OWN socket holds), and the
    # reactors and per-transport watchers the transports used to start from their own #run!.
    #
    # SEAM: the transports expose it themselves - `#adapter` (the declaration the cluster
    # supervises a transport through) and `#bound_port` (the port that transport's own socket
    # bound) are public on Server::Tcp/Server::Udp, and `#supervised_by(cluster)` lets a server
    # adopt a cluster it did not build. No reflection reaches into a transport from here.
    class Multi
      attr_reader :servers, :cluster

      def initialize(servers, protocols: nil, logger: nil)
        @servers = Array(servers)
        @protocols = protocols || @servers.map { |server| protocol_of(server) }
        @logger = logger || Takagi.logger
        # Read the service's ONE count off the transports BEFORE they adopt anything: at this
        # point each still reports the cluster it built, which is the count every transport was
        # constructed with.
        count = @servers.first.cluster.count
        @adapters = @servers.map(&:adapter)
        @ports = @servers.map(&:bound_port)
        @cluster = Cluster.new(count: count, adapters: @adapters, logger: @logger)
        # ONE fan-out, and the transports point at it: each adopts the service's cluster as its
        # supervisor, so `srv.cluster`/`srv.worker_pids` can never report the per-transport
        # cluster this service just replaced, and a serve loop reads the stop flag and the
        # parent-death guard of the cluster that really forked it. `#shutdown!` on one transport
        # still stops only that transport - the service's cluster is stopped here, by
        # #shutdown!.
        @servers.each { |server| server.supervised_by(@cluster) }
      end

      # The pids the cluster supervises for the whole service, by fork order; nil when the
      # service serves in-process and forked nothing. This is the authoritative reader for a
      # multi-transport service; each transport's own #worker_pids reports the same list, because
      # every transport of this service was handed THIS cluster as its supervisor.
      def worker_pids
        @cluster.worker_pids
      end

      # Starts the service: the transports' own boot hooks, the service's threads, then the
      # cluster, which runs every adapter's serve loop in this process at a count of 1 and forks
      # `count` children that each serve EVERY transport above 1.
      def run!
        @servers.zip(@protocols, @ports).each do |_server, protocol, port|
          Takagi::Hooks.emit(:server_starting, protocol: protocol, port: port)
        end
        start_service_threads!
        @cluster.run!
        teardown!
      end

      # Stops the service: the cluster first (children TERM->KILL, then this process's copies of
      # the listeners), then each transport's own teardown - its watcher, its handler pool, its
      # socket and its `:server_stopped` payload. Every transport emits its own stop from its own
      # #shutdown!, so a service that never calls a transport's #run! still reports each stop.
      # Called by #run! when the service ends on its own, and by #shutdown! from the caller's
      # thread, which is why the join of the thread that runs this service lives in #shutdown!
      # and not here.
      def shutdown!
        teardown!

        @server_thread.join(5) if defined?(@server_thread) && @server_thread&.alive?
      end

      private

      def teardown!
        @cluster.shutdown!
        @servers.each(&:shutdown!)
      end

      # Started in the process that BOOTS the service, before the cluster forks: threads do not
      # survive a fork, so a child would inherit their started flags and never re-start them. Each
      # transport starts its own hooks (its watcher, and the reactors for the transports that own
      # them), because only the transport knows what its serving process needs.
      def start_service_threads!
        @servers.each(&:start_service_hooks!)
      end

      def protocol_of(server)
        Registry.protocols.find { |protocol| Registry.get(protocol) == server.class }
      end
    end
  end
end
