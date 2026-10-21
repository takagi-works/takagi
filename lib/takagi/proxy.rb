# frozen_string_literal: true

require 'delegate'

module Takagi
  # The proxy's entry point: one service that listens for the protocols it is given and answers
  # every request with the router and the middleware stack injected here. Rows 2-9 of
  # .omo/plans/coap-proxy.md build the forwarding path on top of it, and none of them constructs a
  # listener of its own.
  #
  # The listeners are ordinary {Server::Udp}/{Server::Tcp} instances - the proxy inherits their
  # serving model, their CSM handshake and their per-transport `bound_port` reader - because both
  # fall back to the process-global `Takagi::Router.instance` when no router is injected, and
  # `Takagi::Base.spawn!` cannot inject one at all (it takes only a port and a protocol list,
  # `base/server_lifecycle.rb`). One {Server::Multi} supervises them, so the transports share ONE
  # cluster and one worker count, exactly as any other multi-transport Takagi service.
  #
  # `port: 0` gives EACH listener its own ephemeral port, so a bound port is always read PER
  # PROTOCOL through {#port} (all of them through {#ports}) and never from the configured value.
  #
  # @example
  #   proxy = Takagi::Proxy.new(route_table: table, port: 0, protocols: [:udp, :tcp])
  #   proxy.port(:udp) # => 41234
  #   proxy.port(:tcp) # => 41235
  class Proxy
    # What a proxy listens for when its caller names nothing else.
    DEFAULT_PROTOCOLS = %i[udp tcp].freeze

    # The route table this proxy resolves through (row 1's object). The entry point HOLDS it: the
    # resolution itself belongs to the forwarding path (row 2).
    attr_reader :route_table

    # The router the listeners are constructed with, so a request the proxy answers ITSELF is
    # resolved through this instance and never through the process-global one.
    attr_reader :router

    # The middleware stack the listeners run.
    attr_reader :middleware_stack

    # The listeners, in `protocols` order.
    attr_reader :servers

    # The object that places a claimed request on the outbound hop (row 2).
    attr_reader :forwarder

    # Binds every listener - each on its own port when `port` is 0 - and the one {Server::Multi}
    # that supervises them.
    #
    # @param route_table [Object] the proxy's route table (row 1); held, never resolved here
    # @param middleware_stack [Takagi::MiddlewareStack, Object, nil] the stack the listeners run,
    #   the process stack by default; it must expose its router through `#router`, because the
    #   router defaults to that one
    # @param port [Integer] what every listener asks the kernel for; 0 chooses one per listener
    # @param protocols [Array<Symbol>] what the proxy listens for
    # @param router [Object, nil] the router handed to every listener, the stack's own by default
    # @param worker_processes [Integer] the ONE worker count of the service, handed to every
    #   listener: the transports of one service never fork different counts
    # @param worker_threads [Integer, nil] threads per serving process; nil keeps the transport's
    #   own default, which is 2 readers for UDP and a thread per connection for TCP
    def initialize(route_table:, middleware_stack: nil, port: 0, # rubocop:disable Metrics/ParameterLists -- a service's transport-config list, as the transports carry
                   protocols: DEFAULT_PROTOCOLS, router: nil, worker_processes: 1,
                   worker_threads: nil, bind_address: '0.0.0.0')
      @bind_address = bind_address
      @route_table = route_table
      @middleware_stack = middleware_stack || Takagi::MiddlewareStack.instance
      @router = router || @middleware_stack.router
      @forwarder = Forwarder.new(route_table: @route_table)
      @discovery = Discovery.new(route_table: @route_table)
      @stack = ForwardingStack.new(route_table: @route_table, forwarder: @forwarder,
                                   discovery: @discovery, local: @middleware_stack)
      @protocols = Array(protocols).map(&:to_sym)
      @servers = @protocols.map { |protocol| build_server(protocol, port, worker_processes, worker_threads) }
      @service = Takagi::Server::Multi.new(@servers, protocols: @protocols)
      @ports = @protocols.zip(@servers.map(&:bound_port)).to_h
      @route_table.register_own_ports(@ports.values)
    end

    # The port the listener for `protocol` actually bound, read off that listener's own socket.
    #
    # @param protocol [Symbol] :udp, :tcp, ...
    # @return [Integer]
    # @raise [ArgumentError] when the proxy does not listen for that protocol
    def port(protocol)
      @ports.fetch(protocol.to_sym) do
        raise ArgumentError, "the proxy listens for #{@protocols.inspect}, not #{protocol.inspect}"
      end
    end

    # Every bound port, keyed by protocol.
    #
    # @return [Hash{Symbol => Integer}]
    def ports
      @ports.dup
    end

    # Serves every listener through the one cluster that supervises them; returns once the service
    # stops.
    def run!
      @service.run!
    end

    # Stops the service and then every listener.
    def shutdown!
      @service.shutdown!
    end

    # The pids the supervising cluster tracks, by fork order; nil when the service serves in this
    # process and forked nothing.
    def worker_pids
      @service.worker_pids
    end

    private

    def build_server(protocol, port, worker_processes, worker_threads)
      options = { port: port, router: @router, middleware_stack: @stack,
                  bind_address: @bind_address }
      options[:worker_processes] = worker_processes if worker_processes
      options[:worker_threads] = worker_threads if worker_threads
      Takagi::Server::Registry.build(protocol, **options)
    end

    # The stack its listeners run: a request the route table CLAIMS goes out on the outbound hop,
    # one that no route claims is answered by the local stack the proxy was given. This is the
    # piece that makes the proxy an ordinary inbound server whose routing half is the route table.
    class ForwardingStack
      # @param route_table [Takagi::Proxy::RouteTable]
      # @param forwarder [Takagi::Proxy::Forwarder]
      # @param local [Object] the stack a request no route claims is answered by
      def initialize(route_table:, forwarder:, discovery:, local:)
        @route_table = route_table
        @forwarder = forwarder
        @discovery = discovery
        @local = local
      end

      # Serves one inbound request.
      #
      # @param request [Takagi::Message::Inbound]
      # @return [Object] the answer the worker turns into a response
      def call(request)
        if discovery_request?(request)
          # A `/.well-known/core` request is a LOCAL path (row 6 criterion (e)) and is never placed on
          # the outbound hop. Its local refusal is decided BEFORE the discovery answer is produced, so
          # an unrecognized critical option draws 4.02 (RFC 7252 5.4.1) rather than a 2.05 masking it.
          return @forwarder.local_refusal(request) || @discovery.answer(request)
        end

        forward_proxy = @forwarder.forward_proxy(request)
        return forward_proxy if forward_proxy

        own_path = @forwarder.own_target_path(request)
        return local(LocalRequest.new(request, own_path)) if own_path

        match = @route_table.resolve(request.uri.path)
        return local(request) unless match

        @forwarder.forward(request, match) || local(request)
      end

      # The LOCAL path: the proxy is an ordinary (non-proxying) endpoint here, so it runs the local
      # stack - after the forwarder's own-endpoint check, which applies RFC 7252 5.4.1's
      # Critical/Elective rule.
      def local(request)
        @forwarder.local_refusal(request) || @local.call(request)
      end

      private

      # Whether the request addresses the proxy's own discovery resource, which the proxy answers
      # itself and never forwards.
      def discovery_request?(request)
        request.uri.path.to_s == Discovery::WELL_KNOWN
      end

      # A request that named the proxy itself, seen by the local stack at the PATH the proxy was
      # addressed at: a forward-proxy request carries no Uri-Path, so the datagram's own path is not
      # the resource the target names.
      class LocalRequest < SimpleDelegator
        def initialize(request, path)
          super(request)
          @uri = Uri.new(request.uri, path)
        end

        attr_reader :uri

        # `Object#method` shadows the request's own `method` reader, so it is delegated by hand.
        def method
          __getobj__.method
        end

        # The request's own URI with the target's path: everything else (scheme, host, port, query)
        # stays what the datagram carried, so the local stack sees a complete URI.
        class Uri < SimpleDelegator
          attr_reader :path

          def initialize(original, path)
            super(original)
            @path = path
          end

          def to_s
            "#{scheme}://#{host}:#{port}#{@path}"
          end
        end
      end

      # The router the local stack resolves through, so a listener handed this stack still finds
      # the router the proxy was configured with.
      def router
        @local.router
      end

      def respond_to_missing?(name, include_private = false)
        @local.respond_to?(name, include_private) || super
      end

      def method_missing(name, ...)
        return @local.public_send(name, ...) if @local.respond_to?(name)

        super
      end
    end
  end
end
