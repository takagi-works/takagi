# frozen_string_literal: true

module Takagi
  class Proxy
    # Answers `/.well-known/core` for the proxy (RFC 7252 5.7.3, RFC 6690 4).
    #
    # `:aggregate` asks every configured backend for its OWN discovery and merges the answers, each
    # entry's path moved under its route's prefix - nothing else about an entry is rewritten, so the
    # document stays valid CoRE Link Format. An unreachable or slow backend is dropped from the
    # answer and named in the log; it never fails the whole document, and a bounded timeout per
    # backend keeps that promise. Nothing is cached: the merge happens per request, so a resource a
    # backend adds is visible on the very next discovery.
    #
    # `:local` lists the proxy's own routes and nothing else.
    class Discovery
      WELL_KNOWN = '/.well-known/core'
      CONTENT_FORMAT = Takagi::Discovery::CoreLinkFormat::CONTENT_FORMAT
      CONTENT_FORMAT_OPTION = CoAP::Registries::Option::CONTENT_FORMAT
      CONTENT = CoAP::Registries::Response::CONTENT

      # @param route_table [Takagi::Proxy::RouteTable]
      # @param timeout [Numeric] seconds to wait for ONE backend's discovery
      # @param logger [Logger] where a backend that did not answer is named
      def initialize(route_table:, timeout: 5, logger: Takagi.logger)
        @route_table = route_table
        @timeout = timeout
        @logger = logger
      end

      # The answer for a `/.well-known/core` request, or nil when the proxy does not aggregate and
      # the request is left to the local stack.
      #
      # @param request [Takagi::Message::Inbound]
      # @return [Takagi::Message::Outbound, nil]
      def answer(request)
        return nil unless request.uri.path.to_s == WELL_KNOWN

        return local(request) if @route_table.discovery == :local

        aggregate(request)
      end

      private

      def local(request)
        payload = @route_table.routes.map(&:prefix).uniq.join(',')
        respond(request, payload)
      end

      def aggregate(request)
        entries = @route_table.routes.flat_map { |route| entries_for(route) }
        respond(request, entries.uniq.join(','))
      end

      def respond(request, payload)
        request.to_response(CONTENT, payload, options: { CONTENT_FORMAT_OPTION => CONTENT_FORMAT })
      end

      def entries_for(route)
        body = fetch(route)
        return [] if body.nil?

        body.to_s.split(',').map { |entry| rewrite(entry, route.prefix) }
      end

      def fetch(route)
        transport = route.outbound || :udp
        client = Takagi::Client.new(
          "#{transport.to_sym == :tcp ? 'coap+tcp' : 'coap'}://#{route.host}:#{route.port}",
          protocol: transport,
          timeout: @timeout,
          use_retransmission: false
        )
        begin
          raw = client.raw_exchange(:get, WELL_KNOWN)
          if raw.nil?
            @logger.warn("proxy discovery: #{route.authority} did not answer")
            return nil
          end

          Takagi::Client::Response.new(raw, transport: transport).payload
        rescue StandardError => e
          @logger.warn("proxy discovery: #{route.authority} failed: #{e.class}: #{e.message}")
          nil
        ensure
          client.close
        end
      end

      # Moves an entry's path under the route prefix, changing nothing else about it.
      def rewrite(entry, prefix)
        entry.to_s.sub(/<([^>]*)>/) { "<#{join(prefix, Regexp.last_match(1))}>" }
      end

      def join(prefix, path)
        base = prefix.to_s.chomp('/')
        suffix = path.to_s
        return base if suffix == '/' || suffix.empty?

        "#{base}#{suffix.start_with?('/') ? suffix : "/#{suffix}"}"
      end
    end
  end
end
