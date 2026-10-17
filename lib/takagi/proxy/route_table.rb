# frozen_string_literal: true

module Takagi
  # CoAP proxying (RFC 7252 5.7). Row 1 of .omo/plans/coap-proxy.md owns the route table in
  # this directory; the proxy's entry point is added by row 10 of that plan, not here.
  #
  # Declared as a CLASS because row 10's entry point is `Takagi::Proxy.new(route_table:, ...)`: a
  # class and a module cannot claim the same constant (Ruby raises TypeError), and lib/takagi.rb
  # eager-loads the gem, so the mismatch would fail `require 'takagi'` for every spec run. Row 10
  # made this one-word change (module -> class) because row 1's session was not reachable to make
  # it; Route and RouteTable nest identically under a class.
  class Proxy
    # One prefix-to-backend mapping of the route table: the URI path prefix the route serves,
    # the backend authority it resolves to, and an optional outbound transport override.
    #
    # `outbound` is nil unless a route names one, and nil means "place the request on the
    # transport it arrived on" (the same-transport default; the override is row 4's).
    class Route
      attr_reader :prefix, :host, :port, :outbound

      def initialize(prefix:, host:, port:, outbound: nil)
        @prefix = prefix
        @host = host
        @port = port
        @outbound = outbound
        @segments = self.class.segments(prefix).freeze
        freeze
      end

      # The number of path segments in the prefix. The longest match wins, so the table orders
      # its routes by this.
      def depth
        @segments.length
      end

      # True when the prefix claims `path`. Matching is segment-aware, so `/sensor` does not
      # capture `/sensors`.
      def matches?(path)
        candidate = self.class.segments(path)
        candidate.length >= depth && candidate.first(depth) == @segments
      end

      # The path the backend sees: `path` with the prefix removed, always absolute.
      def relative_path(path)
        "/#{self.class.segments(path).drop(depth).join('/')}"
      end

      def authority
        "#{host}:#{port}"
      end

      def to_s
        suffix = outbound ? " (#{outbound})" : ''
        "#{prefix} -> #{authority}#{suffix}"
      end

      # Splits a URI path into its segments, discarding the empty ones a leading, trailing or
      # doubled slash would otherwise produce.
      def self.segments(path)
        path.to_s.split('/').reject(&:empty?)
      end
    end

    # Longest-prefix route table: the reverse proxy's namespace-to-backend mapping, built from
    # configuration and validated once at boot (RFC 7252 5.7.3).
    #
    # It keeps no global state and takes its routes as an argument, so a spec - or the proxy
    # built directly by `Takagi::Proxy.new` - constructs one without touching the process
    # configuration.
    class RouteTable
      # A successful lookup: the route that claimed the path plus the path left for its backend.
      Match = Struct.new(:route, :relative_path, keyword_init: true) do
        def backend
          route
        end

        def host
          route.host
        end

        def port
          route.port
        end

        def outbound
          route.outbound
        end

        def to_s
          "#{route} #{relative_path}"
        end
      end

      TRANSPORTS = %i[udp tcp].freeze
      PORT_RANGE = (1..65_535)

      # A name the proxy answers to (RFC 7252 5.10.2): a host, optionally with the port that
      # makes it an authority.
      Name = Struct.new(:host, :port, keyword_init: true)

      attr_reader :routes, :names, :own_ports, :forward, :discovery

      # The forward-proxy modes of RFC 7252 5.10.2: `:deny` refuses every Proxy-Uri/Proxy-Scheme
      # request (5.05), `:configured` serves only an authority one of the routes already names.
      FORWARD_MODES = %i[deny configured].freeze

      # What the proxy does with `/.well-known/core` (RFC 6690 4): `:local` lists the proxy's own
      # routes, `:aggregate` merges every backend's own discovery.
      DISCOVERY_MODES = %i[local aggregate].freeze

      # Builds the table from a process configuration's proxy section.
      #
      # @param config [Takagi::Config] the configuration carrying the `proxy` section
      # @param own_ports [Array<Integer>, nil] the ports this proxy listens on; defaults to the
      #   configured port, which is what lets a bare name in `names` be recognized as our own
      def self.from_config(config, own_ports: nil)
        new(
          routes: config.proxy.routes,
          names: config.proxy.names,
          forward: config.proxy.forward,
          discovery: config.proxy.discovery,
          own_ports: own_ports || [config.port]
        )
      end

      # @param routes [Array<Hash, Route>] the configured routes
      # @param names [Array<String>] every name, alias and numeric address the proxy answers to
      # @param own_ports [Array<Integer>] the ports this proxy listens on
      # @raise [ArgumentError] on an impossible route (relative or empty prefix, duplicate
      #   prefix, malformed backend authority, unknown outbound transport) and on a route that
      #   points at one of our own names/ports
      def initialize(routes:, names: [], forward: :deny, discovery: :local, own_ports: [])
        @forward = normalize_forward(forward)
        @discovery = normalize_discovery(discovery)
        @names = Array(names).map { |name| parse_name(name) }
        @own_ports = Array(own_ports).map { |port| Integer(port) }
        @routes = Array(routes).map { |entry| coerce_route(entry) }.sort_by { |route| -route.depth }.freeze
        validate!
      end

      # Resolves a URI path to the backend that owns it, longest prefix first.
      #
      # @return [Match, nil] the owning route and its relative path, or nil when no route claims
      #   the path - the caller then answers locally instead of forwarding
      def resolve(path)
        route = @routes.find { |candidate| candidate.matches?(path) }
        return nil unless route

        Match.new(route: route, relative_path: route.relative_path(path))
      end

      def prefixes
        @routes.map(&:prefix)
      end

      # Whether this proxy will act as a forward proxy for `authority` ("host:port"). The mode and
      # the authority set are ONE decision, kept here so no second switch exists: a `:deny` proxy
      # serves nobody, and a `:configured` proxy serves exactly the authorities its routes name.
      def serves_forward_proxy?(authority)
        @forward == :configured && !route_for_authority(authority).nil?
      end

      # The route whose backend authority is exactly `authority`, if any.
      def route_for_authority(authority)
        @routes.find { |route| route.authority == authority }
      end

      # Whether `host:port` names the proxy itself (RFC 7252 5.10.2: a proxy MUST recognize all of
      # its server names, aliases, local variations and numeric addresses). The port is part of the
      # authority, so a bare name only identifies us on a port we actually listen on.
      def own_authority?(host, port)
        wanted = host.to_s.downcase
        @names.any? do |name|
          next false unless name.host == wanted

          name.port ? name.port == port : @own_ports.include?(port)
        end
      end

      # Records the ports this proxy actually bound. A proxy built on `port: 0` only learns them
      # after the listeners exist, and the own-name rule needs them to recognize a bare name.
      def register_own_ports(ports)
        @own_ports = (@own_ports + Array(ports).map { |port| Integer(port) }).uniq
      end

      private

      def validate!
        validate_prefixes!
        validate_self_route!
        self
      end

      def validate_prefixes!
        seen = {}
        @routes.each do |route|
          raise ArgumentError, "duplicate proxy route prefix: #{route.prefix.inspect} (#{seen[route.prefix]})" if seen.key?(route.prefix)

          seen[route.prefix] = route
        end
      end

      def validate_self_route!
        route = @routes.find { |candidate| own_route?(candidate) }
        return unless route

        raise ArgumentError, "proxy route #{route} points at the proxy itself; a self-route is the request loop RFC 7252 5.7.2 forbids"
      end

      # A route is ours when its authority is one of the proxy's names. The port is part of the
      # authority, so a bare name (one without a port of its own) only identifies us on a port
      # we actually listen on.
      def own_route?(route)
        own_authority?(route.host, route.port)
      end

      def coerce_route(entry)
        return entry if entry.is_a?(Route)

        Route.new(
          prefix: normalize_prefix(field(entry, :prefix)),
          host: normalize_host(field(entry, :host)),
          port: normalize_port(field(entry, :port)),
          outbound: normalize_outbound(field(entry, :outbound))
        )
      end

      def field(entry, key)
        return entry.key?(key.to_s) ? entry[key.to_s] : entry[key] if entry.is_a?(Hash)

        unless entry.respond_to?(key)
          raise ArgumentError, "invalid proxy route #{entry.inspect}: expected a route mapping or an object answering #{key}"
        end

        entry.public_send(key)
      end

      def normalize_prefix(prefix)
        raise ArgumentError, "proxy route prefix must be an absolute, non-empty path: #{prefix.inspect}" unless absolute?(prefix)

        prefix == '/' ? '/' : prefix.chomp('/')
      end

      def absolute?(prefix)
        prefix.is_a?(String) && prefix.start_with?('/')
      end

      def normalize_host(host)
        name = host.to_s.strip
        raise ArgumentError, "proxy route backend host must not be empty: #{host.inspect}" if name.empty?

        name.downcase.sub(/\A\[(.+)\]\z/, '\1')
      end

      def normalize_port(port)
        value = begin
          Integer(port)
        rescue ArgumentError, TypeError
          raise ArgumentError, "proxy route backend port must be an integer in 1..65535: #{port.inspect}"
        end

        raise ArgumentError, "proxy route backend port #{value} is outside 1..65535" unless PORT_RANGE.cover?(value)

        value
      end

      def normalize_forward(forward)
        value = (forward || :deny).to_s.downcase.to_sym
        return value if FORWARD_MODES.include?(value)

        raise ArgumentError, "proxy forward mode must be one of #{FORWARD_MODES.map(&:inspect).join(', ')}: #{forward.inspect}"
      end

      def normalize_discovery(discovery)
        value = (discovery || :local).to_s.downcase.to_sym
        return value if DISCOVERY_MODES.include?(value)

        raise ArgumentError, "proxy discovery mode must be one of #{DISCOVERY_MODES.map(&:inspect).join(', ')}: #{discovery.inspect}"
      end

      def normalize_outbound(outbound)
        return nil if outbound.nil?

        value = outbound.to_s.downcase.to_sym
        return value if TRANSPORTS.include?(value)

        raise ArgumentError, "proxy route outbound transport must be one of #{TRANSPORTS.map(&:inspect).join(', ')}: #{outbound.inspect}"
      end

      def parse_name(name)
        text = name.to_s.strip
        raise ArgumentError, 'a proxy name must not be empty' if text.empty?

        match = text.match(/\A(\[[^\]]+\]|[^:]+):(\d+)\z/)
        Name.new(host: normalize_host(match ? match[1] : text), port: match && match[2].to_i)
      end
    end
  end
end
