# frozen_string_literal: true

require 'digest'

module Takagi
  class Proxy
    # Places one inbound request on the OUTBOUND hop and hands the backend's answer back to the
    # client that asked (RFC 7252 5.7.2, "Forwarding a Request").
    #
    # Every hop is its OWN exchange. The outbound request carries a token and a Message ID the
    # client machinery mints for it - never the inbound ones - while the reply the original client
    # sees keeps the client's own token and Message ID, because `Inbound#to_response` carries them
    # onto the answer.
    #
    # Two request forms reach it. A request whose path a configured route claims is forwarded to
    # that route's backend. A request carrying Proxy-Uri, or Proxy-Scheme with Uri-* options, is the
    # FORWARD-proxy form of RFC 7252 5.10.2 - `ForwardTarget` works out the destination, and whether
    # the proxy serves it at all is the route table's single decision (`serves_forward_proxy?`).
    #
    # The answers a proxy owes when it cannot forward are the normative codes of RFC 7252
    # 5.7.1/5.7.2/5.9.3.6: an unrecognized UNSAFE option in the request is 4.02 (5.9.2.3), no
    # answer from the backend is 5.04 (5.9.3.5), a response the proxy cannot process is 5.02
    # (5.9.3.3), and a request to act as a forward proxy when unwilling or unable is 5.05
    # (5.9.3.6). The deciding classification for a REQUEST option is Unsafe/Safe-to-Forward, not
    # Critical/Elective: RFC 7252 5.4.1 says the Critical/Elective rules apply to non-proxying
    # endpoints. An unrecognized SAFE option - elective or critical - is forwarded regardless.
    # Reliability and block-wise assembly are PER HOP (RFC 8323 1): the proxy terminates the inbound
    # hop and opens its own outbound hop, so a device only ever needs to know its own transport, and
    # a route may switch the transport underneath it (row 4).
    class Forwarder
      # Options that name the REQUEST TARGET. They are rebuilt for the outbound request from the
      # resolved route and never travel unchanged onto it (RFC 7252 5.7.2 step 2).
      TARGET_OPTIONS = [
        CoAP::Registries::Option::URI_HOST,
        CoAP::Registries::Option::URI_PORT,
        CoAP::Registries::Option::URI_PATH,
        CoAP::Registries::Option::URI_QUERY
      ].freeze

      # The proxy options of the forward-proxy form. They are CONSUMED by the proxy and never
      # travel onto the outbound request (RFC 7252 5.7.2).
      PROXY_URI = CoAP::Registries::Option::PROXY_URI
      PROXY_SCHEME = CoAP::Registries::Option::PROXY_SCHEME

      # Everything the proxy rebuilds or consumes per hop. Block1/Block2 (RFC 7959) are deliberately
      # NOT here: the proxy passes them through untouched and never reassembles or re-blocks.
      CONSUMED_OPTIONS = (TARGET_OPTIONS + [PROXY_URI, PROXY_SCHEME]).freeze

      # The codes this proxy answers itself.
      BAD_OPTION = CoAP::Registries::Response::BAD_OPTION
      BAD_GATEWAY = CoAP::Registries::Response::BAD_GATEWAY
      GATEWAY_TIMEOUT = CoAP::Registries::Response::GATEWAY_TIMEOUT
      PROXYING_NOT_SUPPORTED = CoAP::Registries::Response::PROXYING_NOT_SUPPORTED

      # The CoAP method each request code means on the wire.
      METHODS_BY_CODE = {
        CoAP::Registries::Method::GET => :get,
        CoAP::Registries::Method::POST => :post,
        CoAP::Registries::Method::PUT => :put,
        CoAP::Registries::Method::DELETE => :delete
      }.freeze

      # @param route_table [Takagi::Proxy::RouteTable, nil] the table whose single decision says
      #   whether a forward-proxy request is served
      # @param timeout [Numeric] seconds to wait for the backend's answer
      # @param logger [Logger] where every refusal is reported with its reason and target
      def initialize(route_table: nil, timeout: 5, logger: Takagi.logger)
        @route_table = route_table
        @timeout = timeout
        @logger = logger
        @observe = ObservePolicy.new(logger: logger)
      end

      # Forwards `request` to the backend `match` names and maps the answer back onto the transport
      # the request arrived on; answers the RFC's refusal code instead when it cannot.
      #
      # @param request [Takagi::Message::Inbound]
      # @param match [Takagi::Proxy::RouteTable::Match]
      # @return [Takagi::Message::Outbound]
      def forward(request, match)
        refusal = request_refusal(request)
        return refusal if refusal

        route = match.route
        transport = route.outbound || request.transport
        answer(request, exchange_at(request, route.host, route.port, transport, match.relative_path),
               route.authority, transport)
      end

      # Handles the forward-proxy form (RFC 7252 5.10.2) and returns nil when the request is not one,
      # so ordinary prefix routing applies.
      #
      # @param request [Takagi::Message::Inbound]
      # @return [Takagi::Message::Outbound, nil]
      def forward_proxy(request)
        uri_option = request.options[PROXY_URI]
        scheme_option = request.options[PROXY_SCHEME]
        return nil if uri_option.nil? && scheme_option.nil?

        refusal = request_refusal(request)
        return refusal if refusal

        return mixed_target_refusal(request) if uri_option && uri_target_present?(request)

        serve_forward_proxy(request, ForwardTarget.for(request, uri_option, scheme_option))
      end

      # The proxy's own-endpoint check for the LOCAL path: RFC 7252 5.4.1's Critical/Elective rule
      # applies to a non-proxying endpoint, which the proxy is when it answers locally.
      #
      # @param request [Takagi::Message::Inbound]
      # @return [Takagi::Message::Outbound, nil] nil when the request may be handled locally
      def local_refusal(request)
        critical = OptionRules.unrecognized_critical(request.options)
        return nil if critical.empty?

        refuse(request, BAD_OPTION, "unrecognized critical option(s) #{critical.inspect} for local handling")
      end

      # The path a forward-proxy request names when that request identifies the PROXY ITSELF, or nil.
      # The stack answers such a request from the proxy's own routes at exactly that path (RFC 7252
      # 5.7.2's local-request rule); it is never forwarded, which is what makes a loop impossible.
      #
      # @param request [Takagi::Message::Inbound]
      # @return [String, nil]
      def own_target_path(request)
        uri_option = request.options[PROXY_URI]
        scheme_option = request.options[PROXY_SCHEME]
        return nil if uri_option.nil? && scheme_option.nil?

        target = ForwardTarget.for(request, uri_option, scheme_option)
        return nil unless target && own_target?(target)

        @logger.warn("proxy treating #{target.authority} as LOCAL: it is one of the proxy's own names")
        target.path
      end

      private

      def serve_forward_proxy(request, target)
        return refuse(request, BAD_OPTION, 'a forward-proxy request must name an absolute URI') if target.nil?
        return nil if own_target?(target)

        transport = ForwardTarget.transport_for(target.scheme)
        return refuse(request, PROXYING_NOT_SUPPORTED, "unsupported scheme #{target.scheme.inspect}") unless transport
        unless @route_table&.serves_forward_proxy?(target.authority)
          return refuse(request, PROXYING_NOT_SUPPORTED, "this proxy will not forward-proxy to #{target.authority}")
        end

        answer(request, exchange_at(request, target.host, target.port, transport, target.path, target: target),
               target.authority, transport)
      end

      # RFC 7252 5.10.2: Proxy-Uri "MUST take precedence over any of the Uri-Host, Uri-Port,
      # Uri-Path or Uri-Query options (each of which MUST NOT be included in a request containing
      # the Proxy-Uri Option)" - so the combination is refused rather than silently resolved.
      def mixed_target_refusal(request)
        refuse(request, BAD_OPTION,
               'Proxy-Uri MUST NOT be combined with any Uri-Host/Uri-Port/Uri-Path/Uri-Query option')
      end

      def uri_target_present?(request)
        TARGET_OPTIONS.any? { |number| request.options.key?(number) }
      end

      # RFC 7252 5.7.2: a request whose authority identifies the proxy itself MUST be treated as a
      # LOCAL (non-proxied) request - that is the mechanism that makes a request loop impossible.
      def own_target?(target)
        @route_table&.own_authority?(target.host, target.port) || false
      end

      # One outbound hop to an explicit authority. `target`, when given, is the forward-proxy
      # destination whose authority is written back as Uri-Host/Uri-Port (nil on a prefix route).
      def exchange_at(request, host, port, transport, path, target: nil)
        endpoint = endpoint_for(host, port, transport)
        client = Takagi::Client.new(
          endpoint,
          protocol: transport,
          timeout: @timeout,
          use_retransmission: false
        )
        begin
          place(client, request, path, transport, endpoint, target)
        ensure
          client.close
        end
      end

      def place(client, request, path, transport, endpoint, target = nil)
        raw = client.raw_exchange(method_of(request), path, request.payload,
                                  options: forwarded_options(request, target),
                                  token: outbound_token(request, endpoint))
        return :no_answer if raw.nil?

        Takagi::Client::Response.new(raw, transport: transport)
      rescue Takagi::Message::ParseError
        :unprocessable
      end

      # Maps one hop's outcome onto the answer the client sees, or onto the RFC's refusal code. The
      # answer is either a parsed response, :no_answer (the backend did not reply - 5.04) or
      # :unprocessable (it replied with bytes that do not parse - 5.02), and those last two are
      # exactly the distinction the public client API collapses into nil.
      def answer(request, outcome, authority, transport)
        return refuse(request, GATEWAY_TIMEOUT, "no answer from #{authority}") if outcome == :no_answer
        return unparseable(request, authority) if outcome == :unprocessable

        refusal = response_refusal(request, outcome, authority)
        return refusal if refusal

        emit_forwarded(request, outcome, authority, transport)
      end

      def unparseable(request, authority)
        refuse(request, BAD_GATEWAY, "#{authority} answered with bytes this proxy cannot parse")
      end

      # The library presents a GET that carries Observe as method "OBSERVE" (`message/base.rb:30`),
      # but the wire method of such a request is still GET - the outbound hop must carry a real
      # method, so it is read off the CODE rather than the presentation.
      def method_of(request)
        METHODS_BY_CODE.fetch(request.code) { request.method.to_s.downcase.to_sym }
      end

      # A block-wise exchange reaches the next hop as SEVERAL requests, and that hop assembles them
      # per token: a token drawn fresh per datagram would make every block its own exchange and the
      # upload impossible. The outbound token is therefore DERIVED from the inbound one - still a
      # different token on every hop (RFC 7252 5.7.2 re-origination), but stable across the blocks of
      # one exchange. Known limitation: two clients that choose the same inbound token for the same
      # endpoint would share an outbound token, because this plan keeps no per-token state.
      def outbound_token(request, endpoint)
        Digest::SHA256.digest("#{endpoint}/#{request.token}")[0, 8]
      end

      # The request-side rule: an unrecognized UNSAFE option is refused before anything is placed on
      # the outbound hop (RFC 7252 5.7.1).
      def request_refusal(request)
        unsafe = OptionRules.unrecognized_unsafe(request.options)
        return nil if unsafe.empty?

        refuse(request, BAD_OPTION, "unrecognized unsafe option(s) #{unsafe.inspect} in the request")
      end

      # The response-side rule of the same section: an unrecognized UNSAFE option in the backend's
      # answer makes the answer unprocessable.
      def response_refusal(request, response, authority)
        unsafe = OptionRules.unrecognized_unsafe(response.options)
        return nil if unsafe.empty?

        refuse(request, BAD_GATEWAY,
               "#{authority} answered with unrecognized unsafe option(s) #{unsafe.inspect}")
      end

      def emit_forwarded(request, response, authority, transport)
        Takagi::Hooks.emit(
          :proxy_forwarded,
          target: authority,
          protocol: transport,
          token: response.token,
          message_id: response.inbound.message_id,
          backend: authority
        )
        request.to_response(response.code, response.payload, options: reply_options(response))
      end

      # The endpoint URI an outbound hop is placed on.
      def endpoint_for(host, port, transport)
        scheme = transport.to_sym == :tcp ? 'coap+tcp' : 'coap'
        "#{scheme}://#{bracketed_host(host)}:#{port}"
      end

      # `host` is the proxy's canonical, UNBRACKETED authority host, but every place it leaves the
      # proxy carries a URI host, and an IPv6 literal is written with brackets in BOTH: RFC 3986
      # 3.2.2 brackets it inside a URI authority, and RFC 7252 6.1 adopts IP-literal from RFC 3986
      # - whose production is "[" ( IPv6address / IPvFuture ) "]", brackets included - so 6.5 step
      # 2 fails a Uri-Host value that is not a valid reg-name, IP-literal or IPv4address. Without
      # this, an IPv6 backend produced the malformed `Uri-Host: 2001:db8::2:1`.
      def bracketed_host(host)
        host.include?(':') && !host.start_with?('[') ? "[#{host}]" : host
      end

      def refuse(request, code, reason)
        @logger.warn("proxy refusing #{request.uri.path} with #{CoAP::CodeHelpers.to_string(code)}: #{reason}")
        request.to_response(code, nil)
      end

      # RFC 7252 5.7.2: for a CoAP-to-CoAP proxy "the request URI is decoded and split into the
      # Uri-Host, Uri-Port, Uri-Path and Uri-Query Options", which "consumes the Proxy-Uri or
      # Proxy-Scheme option". Uri-Path and Uri-Query come from the path the client machinery is
      # handed; Uri-Host and Uri-Port are rebuilt from `target` here, because `reject_consumed`
      # strips the inbound ones and `Message::Request#build_options` derives only the path and the
      # query.
      #
      # `target` is the resolved forward-proxy destination, nil on the prefix-route hop, whose
      # destination is the route's own authority rather than a URI the client named (RFC 7252 5.7.3).
      def forwarded_options(request, target = nil)
        options = reject_consumed(request.options)
        options[CoAP::Registries::Option::URI_HOST] = bracketed_host(target.host) if target
        options[CoAP::Registries::Option::URI_PORT] = target.port if target
        @observe.forwarded_options(request, options)
      end

      def reply_options(response)
        @observe.reply_options(reject_consumed(response.options))
      end

      def reject_consumed(options)
        (options || {}).except(*CONSUMED_OPTIONS)
      end
    end
  end
end
