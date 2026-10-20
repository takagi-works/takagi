# frozen_string_literal: true

require_relative '../branding'

module Takagi
  class Base < Router
    # Manages server lifecycle operations: booting, running, and spawning servers.
    #
    # Extracted from Base class to follow Single Responsibility Principle.
    # Handles configuration loading, server instantiation, and process management.
    module ServerLifecycle
      # Boots the application by loading configuration and running initializers
      #
      # @param config_path [String] Path to configuration file
      def boot!(config_path: 'config/takagi.yml')
        Takagi.config.load_file(config_path) if File.exist?(config_path)
        Takagi::Initializer.run!
        # ONE background cleaner for the observer subscriptions, started here at boot and
        # idempotent across repeated boots: Observer::Registry owns both the subscriptions
        # and the thread that expires them.
        Takagi::Observer::Registry.start_cleanup
      end

      # Runs the server in the foreground (blocking)
      #
      # @param port [Integer, nil] Port to bind to (uses config if nil)
      # @param config_path [String] Path to configuration file
      # @param protocols [Array<Symbol>, nil] Protocols to enable (uses config if nil)
      # @param router [Router, CompositeRouter, nil] Custom router (uses global if nil)
      # @param banner [Boolean] Show startup banner (default: true)
      def run!(port: nil, config_path: 'config/takagi.yml', protocols: nil, router: nil, banner: true)
        boot!(config_path: config_path)
        enable_plugins!(app: self)

        # Show startup banner
        if banner
          print_startup_banner(
            port: port || Takagi.config.port,
            protocols: protocols || Takagi.config.protocols,
            router: router || self.router  # Pass router to banner
          )
        end

        selected_port = port || Takagi.config.port
        selected_protocols = Array(protocols || Takagi.config.protocols).map(&:to_sym)
        servers = build_servers(selected_protocols, selected_port, router: router)
        announce_service_boot(protocols: selected_protocols, servers: servers)
        run_servers(servers, selected_protocols)
      end

      # Spawns servers in background threads
      #
      # @param port [Integer] Port to bind to
      # @param protocols [Array<Symbol>, nil] Protocols to enable (uses config if nil)
      # @return [Server, Multi] The spawned server instance
      def spawn!(port: 5683, protocols: nil)
        protos = if protocols
                   Array(protocols)
                 else
                   Takagi.config.protocols
                 end.map(&:to_sym)

        servers = build_servers(protos, port)
        announce_service_boot(protocols: protos, servers: servers)

        if servers.length == 1
          server = servers.first
          thread = Thread.new { server.run! }
          # Store thread reference on the server instance for cleanup
          server.instance_variable_set(:@server_thread, thread)
          server
        else
          multi = Takagi::Server::Multi.new(servers, protocols: protos)
          thread = Thread.new { multi.run! }
          # Store thread reference on the multi instance for cleanup
          multi.instance_variable_set(:@server_thread, thread)
          multi
        end
      end

      private

      # Prints startup banner with Takagi branding
      #
      # @param port [Integer] Port server will bind to
      # @param protocols [Array<Symbol>] Protocols being enabled
      # @param router [Router] Router instance to count routes from
      def print_startup_banner(port:, protocols:, router:)
        # Print banner
        Branding.print_banner(compact: false)

        # Version info
        version = defined?(Takagi::VERSION) ? Takagi::VERSION : '0.1.0'
        Branding.print_version(version)

        puts
        puts Branding.section('Starting Server')

        # Server info
        puts Branding.log("Port: #{port}")
        puts Branding.log("Protocols: #{protocols.map(&:to_s).map(&:upcase).join(', ')}")
        puts Branding.log("Threads: #{Takagi.config.threads}")
        puts Branding.log("Processes: #{Takagi.config.processes}") if Takagi.config.processes > 0

        # Route count
        route_count = router.route_count
        puts Branding.log("Routes registered: #{route_count}")

        puts
        puts Branding.success('Server starting...')
        puts Branding.info('Press Ctrl+C to shutdown')
        puts
        puts Branding::WAVE_LINE
        puts
      end

      # Builds server instances for the given protocols
      #
      # @param protocols [Array<Symbol>] Protocol identifiers
      # @param port [Integer] Port to bind to
      # @param router [Router, CompositeRouter, nil] Custom router (uses global if nil)
      # @return [Array<Server>] Array of server instances
      def build_servers(protocols, port, router: nil)
        # ONE worker count per service: resolve it once, here, before any server exists. Every
        # transport forks this same number, and a per-protocol `processes` only restates it.
        processes = resolve_service_processes!
        Array(protocols).map(&:to_sym).map do |protocol|
          settings = Takagi.config.protocol_settings[protocol] || {}
          apply_concurrency_vocabulary!(protocol, settings)
          instantiate_server(
            protocol,
            port,
            threads: settings[:threads] || Takagi.config.threads,
            processes: processes,
            max_connections: settings[:max_connections] || Takagi.config.max_connections,
            router: router
          )
        end
      end

      # Instantiates a server for the given protocol using ServerRegistry
      #
      # @param protocol [Symbol] Protocol identifier (:udp, :tcp, etc.)
      # @param port [Integer] Port to bind to
      # @param threads [Integer] Number of worker threads
      # @param processes [Integer] The service's ONE resolved worker count, the same value
      #   handed to every transport
      # @param router [Router, CompositeRouter, nil] Custom router (uses global if nil)
      # @return [Server] Server instance
      def instantiate_server(protocol, port, threads:, processes:, max_connections: nil, router: nil)
        options = { port: port }
        # A server's `threads` is its own pool size. UDP's readers always take the
        # resolved value, the global default included, because that is how they have
        # always been configured. A TCP handler pool is opt-in on the protocol's OWN key:
        # a count inherited from an untouched global default would put a bounded pool under
        # every existing TCP deployment and change its serving behaviour, while a written
        # `protocol_settings[:tcp][:threads]` is a request for bounded concurrency and does
        # reach the pool.
        options[:worker_threads] = threads if protocol == :udp || per_protocol_threads?(protocol)
        options[:router] = router if router

        # Every transport forks the service's ONE worker count, so the resolved number always
        # reaches the server: `1` is the in-process shape, not an absent key - unlike `threads`,
        # where a count inherited from an untouched global default would put a bounded pool under
        # every existing deployment.
        options[:worker_processes] = processes
        options[:max_connections] = max_connections if protocol == :tcp && max_connections
        Takagi.logger.debug("Instantiating server for #{protocol} on port #{port} with #{options}")
        Server::Registry.build(protocol, **options)
      end

      # True when the protocol's own settings carry a `threads` count: the presence is
      # what opens the TCP handler pool, so the resolved number alone cannot decide it.
      def per_protocol_threads?(protocol) = !Takagi.config.protocol_settings.dig(protocol, :threads).nil?

      # Runs servers (single or multi-protocol)
      #
      # @param servers [Array<Server>] Server instances to run
      # @param protocols [Array<Symbol>, nil] The transports `servers` were built for, in that
      #   order, so the fan-out can name each one in that transport's own boot payload
      def run_servers(servers, protocols = nil)
        return servers.first.run! if servers.length == 1

        Takagi::Server::Multi.new(servers, protocols: protocols).run!
      end
    end

    # The single concurrency vocabulary, and the one place a server's settings are checked
    # against it. It is REOPENED here rather than grown in place so the documented body above
    # keeps the line numbers the configuration documentation cites, and so no single module
    # definition has to carry every method this vocabulary needs.
    #
    # - `processes` is OS processes per SERVICE: it is the ONE count the cluster forks and it
    #   reaches every transport the service exposes, so the top-level key is the count and a
    #   per-protocol `processes` is accepted only as a compatibility alias that restates it
    #   (see `resolve_service_processes!`).
    # - `threads` is concurrency units per PROCESS: UDP's readers, the TCP handler pool and, on
    #   its own level, a controller's own pool. For a server the per-protocol key beats the
    #   global default; a controller's pool is its own and no server-level value overrides it.
    # - `max_connections` is a per-WORKER accepted-connection cap, so it belongs to the transport
    #   that accepts connections; a datagram transport has no room for it.
    #
    # Precedence is per key and no layer is silent: a key written at the per-protocol layer that
    # its target cannot apply raises, naming key, target and reason, while a GLOBAL key a target
    # cannot consume warns once at boot with the same three facts plus the exact per-protocol
    # line to write instead - raising for a global key would break the configurations that write
    # only global values today.
    module ServerLifecycle
      # The transports whose serving pool takes the global `threads` value as its own size. Every
      # other target opens its pool only on the protocol's own key, so a written global count
      # either belongs to this list or is reported once instead of being dropped in silence.
      GLOBAL_THREADS_CONSUMERS = [:udp].freeze

      # Validates and reports the concurrency keys of one protocol's settings: the per-protocol
      # rejections first (they are fatal), then the global keys this target cannot consume.
      def apply_concurrency_vocabulary!(protocol, settings)
        reject_inapplicable_protocol_keys!
        warn_about_unconsumed_globals(protocol, settings)
      end

      # ONE worker count per service: `processes` is the number of OS processes the cluster
      # forks for the WHOLE service and reaches every transport it exposes, so a per-protocol
      # `processes` is not a scaling knob - it survives only as a compatibility alias, accepted
      # when it restates the service's one count. Resolved once per build.
      def resolve_service_processes!
        counts = configured_process_counts
        values = counts.map(&:last).uniq
        return values.first || Takagi.config.processes if values.size <= 1

        disagreeing_worker_counts!(counts)
      end

      # Every WRITTEN `processes` value, paired with the layer that carries it. The top-level key
      # counts only when the configuration actually carried it, so the untouched default never
      # turns a lone per-protocol count into a disagreement, and no key nobody wrote can make
      # this raise.
      def configured_process_counts
        counts = []
        counts << [:global, Takagi.config.processes] if Takagi.config.written?(:processes)
        Takagi.config.protocol_settings.each do |transport, settings|
          counts << [transport, settings[:processes]] if settings.key?(:processes)
        end
        counts
      end

      # The refusal: key, targets, reason, remedy - the same shape the max_connections refusal
      # carries, in the same place a boot fails loudly rather than dropping a written value.
      def disagreeing_worker_counts!(counts)
        described = counts.map { |source, value| "#{process_count_source(source)} = #{value}" }.join(' and ')
        raise ArgumentError,
              "a service has ONE worker count, but the configured counts disagree: #{described}. " \
              '`processes` is the number of OS processes the cluster forks for the whole service, so ' \
              'every transport it exposes serves the same count; a per-protocol `processes` is accepted ' \
              'only when it restates that one count. Keep one number - write `processes: <N>` at the top ' \
              'level, or make every `protocol_settings[<transport>][:processes]` agree - and use ' \
              '`protocol_settings[<transport>][:threads]` for per-transport concurrency.'
      end

      def process_count_source(source)
        source == :global ? 'the top-level `processes`' : "protocol_settings[:#{source}][:processes]"
      end

      # A per-protocol key its target cannot apply raises instead of vanishing in
      # `instantiate_server`: `protocol_settings[:udp][:max_connections]` was dropped in silence.
      def reject_inapplicable_protocol_keys!
        Takagi.config.protocol_settings.each do |target, settings|
          next if settings[:max_connections].nil? || accepts_max_connections?(target)

          raise ArgumentError,
                "protocol_settings[:#{target}][:max_connections] cannot apply to the :#{target} target: " \
                "`max_connections` is the TCP server's per-worker accepted-connection cap, and :#{target} " \
                'accepts no connections, so the written value would be dropped in silence. Scope such a ' \
                'cap to the server that accepts connections: `protocol_settings: { tcp: { max_connections: <N> } }`.'
        end
      end

      # A global key a target cannot consume is reported once, with the same three facts the
      # raise above carries plus the per-protocol line to write instead.
      def warn_about_unconsumed_globals(protocol, settings)
        warn_about_unconsumed_max_connections(protocol)
        warn_about_unconsumed_threads(protocol, settings)
      end

      # A global `max_connections` with a datagram target was dropped in silence: the UDP server
      # is never given the key, so the written cap capped nothing.
      def warn_about_unconsumed_max_connections(protocol)
        global = Takagi.config.max_connections
        return if global.nil? || accepts_max_connections?(protocol)

        Takagi.logger.warn(
          "Ignoring the global `max_connections: #{global}` for protocol :#{protocol}: it is a " \
          "server-wide default for the TCP server's per-worker accepted-connection cap, and " \
          ":#{protocol} accepts no connections. Write " \
          "`protocol_settings: { tcp: { max_connections: #{global} } }` in takagi.yml to cap the " \
          "TCP server's accepted connections instead."
        )
      end

      # A WRITTEN global `threads` count a target does not consume was dropped in silence: that
      # transport's pool opens only on the protocol's own key. The trigger is the key's presence,
      # not its value, so a written count of 1 is still reported while the untouched default is not.
      def warn_about_unconsumed_threads(protocol, settings)
        global = Takagi.config.threads.to_i
        return if !Takagi.config.written?(:threads) || GLOBAL_THREADS_CONSUMERS.include?(protocol) || settings.key?(:threads)

        Takagi.logger.warn(
          "Ignoring the global `threads: #{global}` for protocol :#{protocol}: its handler pool opens " \
          "only on :#{protocol}'s own key, so this count is not applied to this transport, and a pool " \
          "built from it would change how existing :#{protocol} deployments serve: it was written for " \
          "the whole deployment rather than for :#{protocol}. Write `protocol_settings: { #{protocol}: " \
          "{ threads: #{global} } }` in takagi.yml to run a #{global}-thread :#{protocol} handler pool."
        )
      end

      # Whether the server a protocol builds consumes a `max_connections` key at all, read off
      # the server class instead of a hardcoded list: a transport that accepts connections is
      # never refused the key, and a datagram transport is never handed one in silence. A
      # constructor taking `**options` may consume it itself, and a target with no registered
      # server has none to ask, so both count as capable.
      def accepts_max_connections?(protocol)
        parameters = Server::Registry.get(protocol).instance_method(:initialize).parameters
        named = parameters.any? { |kind, name| name == :max_connections && %i[key keyreq].include?(kind) }
        catch_all = parameters.any? { |kind, _name| %i[keyrest rest].include?(kind) }

        named || catch_all
      rescue Takagi::Registry::Base::NotFoundError
        true
      end
    end

    # The service's ONE boot surface: the transport set, the ONE worker count every transport was
    # built with, and EACH transport's HONEST bound port - the port its own socket really holds,
    # which is not the requested one when `port: 0` let the kernel choose, the two transports
    # then being handed different ports. Reported once per service as the `:service_starting`
    # hook payload and one boot-log line, ALONGSIDE the transports' own `:server_starting`
    # payloads, whose keys are never touched.
    module ServerLifecycle
      def announce_service_boot(protocols:, servers:)
        payload = {
          protocols: protocols,
          processes: servers.first.cluster.count,
          ports: protocols.zip(servers).to_h { |protocol, server| [protocol, bound_port_of(server)] },
          pid: Process.pid
        }
        puts Branding.log(service_boot_line(payload))
        Takagi::Hooks.emit(:service_starting, payload)
        payload
      end

      def service_boot_line(payload)
        ports = payload[:ports].map { |protocol, port| "#{protocol}:#{port}" }.join(',')
        "service boot: pid=#{payload[:pid]} protocols=#{payload[:protocols].join(',')} " \
          "processes=#{payload[:processes]} ports=#{ports}"
      end

      # The port a transport's OWN socket holds. A transport declares its already-bound sockets to
      # the cluster through its adapter (`Cluster::Adapter#fds`) AND exposes the same fact itself
      # through its public `#bound_port` reader, so this asks the transport and never reaches into
      # it (see Server::Tcp#bound_port / Server::Udp#bound_port - the socket remains the one
      # source both surfaces read).
      def bound_port_of(server)
        server.bound_port
      end
    end
  end
end
