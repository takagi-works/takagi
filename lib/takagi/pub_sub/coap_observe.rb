# frozen_string_literal: true

module Takagi
  module PubSub
    # The RFC 7641 observe binding, the publish/subscribe transport this change ships.
    #
    # What the binding can carry is derived from the underlying CoAP transport's own
    # declaration (`Network::Base#reliable?`) rather than assumed (design D6): a reliable
    # transport carries no Reset and no message type (RFC 8323 §3, §3.1), and block-wise
    # transfer over it (BERT) is out of scope, so the binding declines those capabilities
    # over :tcp and offers them over :udp.
    class CoapObserve
      # Largest notification representation this binding can deliver in one message:
      # one UDP datagram, or the CSM-negotiated Max-Message-Size over TCP.
      MAX_NOTIFICATION_SIZE = { udp: 65_535, tcp: 8_388_864 }.freeze

      def self.for(transport)
        @instances ||= {}
        @instances[transport.to_sym] ||= new(transport: transport)
      end

      # @param transport [Symbol] the underlying CoAP transport (:udp or :tcp)
      def initialize(transport: :udp)
        @transport = transport.to_sym
      end

      # The name this transport registers under.
      #
      # @return [Symbol]
      def name
        :coap_observe
      end

      # The declared capabilities for this binding's underlying CoAP transport. Every
      # capability the vocabulary lists is present; `block_wise` is the binding's own
      # declaration that the guard example keeps in step with the CSM option list.
      #
      # @return [Hash]
      def capabilities
        {
          subscription_confirmed: !reliable?,      # registration is confirmed over datagrams
          ordered_notifications: true,             # Observe sequences are strictly increasing
          carries_reset: !reliable?,               # RFC 8323 §3.1: no Reset over reliable transports
          pattern_filters: false,                  # RFC 7641 observes one named resource
          max_notification_size: MAX_NOTIFICATION_SIZE[@transport],
          block_wise: !reliable?                   # RFC 7959 first block over datagrams only
        }
      end

      # The binding's own transport, so a caller that resolved the registry entry can still
      # ask for the sibling transport's declaration.
      #
      # @param transport [Symbol]
      # @return [CoapObserve]
      def for_transport(transport)
        self.class.for(transport)
      end

      # The CoAP message type notifications travel as: NON by default, CON where a liveness
      # check applies, and none over a reliable transport (RFC 8323 §3).
      #
      # @param liveness_check [Boolean]
      # @return [Integer, nil]
      def notification_type(liveness_check: false)
        return nil if reliable?
        return CoAP::Registries::MessageType::CON if liveness_check

        CoAP::Registries::MessageType::NON
      end

      private

      def reliable?
        transport_class = Takagi::Network::Registry.get(@transport)
        transport_class.reliable?
      rescue Takagi::Registry::Base::NotFoundError
        false
      end
    end
  end
end
