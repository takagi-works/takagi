# frozen_string_literal: true

module Takagi
  class Proxy
    # The absolute destination a forward-proxy request names (RFC 7252 5.10.2).
    #
    # A Proxy-Uri carries the destination whole and the proxy splits it into Uri-Host/Uri-Port/
    # Uri-Path/Uri-Query for the outbound request; a Proxy-Scheme request carries the scheme alone
    # and the rest is assembled from the request's own Uri-* options.
    class ForwardTarget
      # Host, port, path (with any query) and scheme of the destination.
      Target = Struct.new(:host, :port, :path, :scheme, keyword_init: true) do
        def authority
          "#{host}:#{port}"
        end
      end

      DEFAULT_PORT = 5683

      # @param request [Takagi::Message::Inbound]
      # @param uri_option [String, nil] the Proxy-Uri value
      # @param scheme_option [String, nil] the Proxy-Scheme value
      # @return [Target, nil] nil when the request names no usable absolute URI
      def self.for(request, uri_option, scheme_option)
        new(request, uri_option, scheme_option).target
      end

      # The transport a scheme maps to.
      #
      # @param scheme [String] e.g. "coap" or "coap+tcp"
      # @return [Symbol] :udp or :tcp
      def self.transport_for(scheme)
        scheme.to_s.downcase == 'coap+tcp' ? :tcp : :udp
      end

      def initialize(request, uri_option, scheme_option)
        @request = request
        @uri_option = uri_option
        @scheme_option = scheme_option
      end

      # @return [Target, nil]
      def target
        return from_uri(@uri_option) if @uri_option

        from_scheme
      end

      private

      def from_uri(text)
        uri = URI.parse(text.to_s)
        return nil if uri.host.nil?

        scheme = uri.scheme.to_s.downcase
        Target.new(host: uri.host.to_s.downcase, port: uri.port || DEFAULT_PORT,
                   path: path_with_query(uri), scheme: scheme)
      rescue URI::InvalidURIError
        nil
      end

      # Proxy-Scheme assembles the URI from the Uri-* options and replaces the scheme.
      def from_scheme
        host = @request.options[CoAP::Registries::Option::URI_HOST]
        return nil if host.nil?

        Target.new(host: host.to_s.downcase, port: uri_port, path: path_from_request,
                   scheme: @scheme_option.to_s.downcase)
      end

      def uri_port
        uint_option(CoAP::Registries::Option::URI_PORT) || DEFAULT_PORT
      end

      def path_from_request
        query = @request.options[CoAP::Registries::Option::URI_QUERY]
        query = query.join('&') if query.is_a?(Array)
        path = @request.uri.path
        query ? "#{path}?#{query}" : path
      end

      def path_with_query(uri)
        path = uri.path.to_s.empty? ? '/' : uri.path
        uri.query ? "#{path}?#{uri.query}" : path
      end

      # A CoAP uint option arrives as its raw big-endian bytes (the Inbound does not decode it), so
      # Uri-Port is read here rather than trusted to be a number.
      def uint_option(number)
        raw = @request.options[number]
        return nil if raw.nil?

        bytes = (raw.is_a?(Array) ? raw.first : raw).to_s.b
        return 0 if bytes.empty?

        bytes.bytes.reduce(0) { |acc, byte| (acc << 8) | byte }
      end
    end
  end
end
