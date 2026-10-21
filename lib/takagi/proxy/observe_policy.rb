# frozen_string_literal: true

module Takagi
  class Proxy
    # The one place the proxy decides what happens to RFC 7641's Observe option.
    #
    # This plan does NOT carry a subscription across the proxy, and it takes the licence RFC 7641 5
    # gives for exactly that ("If the response returned by the next hop doesn't include an Observe
    # Option, the intermediary MAY resort to polling the next hop or MAY itself return a response
    # without an Observe Option"). It does it in the strongest available form: the Observe option is
    # dropped from the forwarded request, so the proxy never opens an observation at the backend in
    # the first place - there is no observation to cancel, nothing to poll, and no notification that
    # could follow. A single response is returned, without Observe.
    #
    # Every decision is logged rather than silent, and CONSUMPTION is the only place this option is
    # touched, so no code path can disagree with another.
    #
    # Deviation, recorded deliberately: the plan's "What to do" also describes CANCELLING an
    # observation the proxy opened at the backend (a RST, or a GET with Observe=1, RFC 7641 3.5/3.6).
    # Because this implementation never opens one, that step is moot rather than skipped - the
    # acceptance criteria (exactly one response, no notification) follow a fortiori. If the plan ever
    # wants the proxy to poll the next hop instead, this is the file that changes.
    class ObservePolicy
      OBSERVE = CoAP::Registries::Option::OBSERVE

      # @param logger [Logger] where a dropped subscription is reported
      def initialize(logger: Takagi.logger)
        @logger = logger
      end

      # Whether the request asks to observe.
      #
      # @param request [Takagi::Message::Inbound]
      # @return [Boolean]
      def observing?(request)
        (request.options || {}).key?(OBSERVE)
      end

      # The options the outbound request carries: Observe is dropped so no observation is opened.
      #
      # @param request [Takagi::Message::Inbound]
      # @param options [Hash] the already-rebuilt outbound options
      # @return [Hash]
      def forwarded_options(request, options)
        return options unless observing?(request)

        @logger.warn('proxy does not relay observations: dropping Observe from the forwarded request')
        options.except(OBSERVE)
      end

      # The options the client's response carries: Observe is never handed back, so the client never
      # believes it holds a subscription.
      #
      # @param options [Hash, nil] the backend's response options
      # @return [Hash]
      def reply_options(options)
        (options || {}).except(OBSERVE)
      end
    end
  end
end
