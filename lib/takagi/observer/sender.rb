# frozen_string_literal: true

require 'digest'
require_relative '../coap/block_wise'
require_relative '../pub_sub/coap_observe'

module Takagi
  module Observer
    # Dispatches outbound notifications to subscribed observers.
    # Supports multiple transports (UDP, TCP, etc.) via transport registry.
    #
    # A notification whose value does not fit one datagram goes out block-wise
    # (RFC 7959 §3.4): the notification carries the first Block2 block and the observer
    # retrieves the remaining blocks with further requests. The value is sliced with
    # {Takagi::CoAP::BlockWise.slice}, the same engine the BlockWise middleware slices
    # responses with, and the Block2/Size2/ETag options match the ones
    # {Takagi::Middleware::BlockWise} puts on a response, so a notification and a GET of
    # the same resource produce one continuous block sequence.
    class Sender
      def initialize(transport: :udp)
        @transport = transport
        # NEW: Use transport registry to get appropriate sender
        transport_class = Takagi::Network::Registry.get(@transport)
        transport_impl = transport_class.new
        @sender = transport_impl.create_sender
      rescue Takagi::Network::Registry::TransportNotFoundError
        # Fallback to UDP if transport not found
        Takagi.logger.warn "Transport #{@transport} not found, using UDP"
        @sender = Takagi::Network::UdpSender.instance
      end

      # Sends one notification to a subscriber, block-wise when the value exceeds one
      # datagram.
      #
      # A value that fits one block travels in a single datagram with no Block2 option,
      # exactly as before; a larger one is delivered as the first block of a block-wise
      # transfer (see {#notification}). Errors are logged, never raised: one unreachable
      # subscriber must not stop the other notifications.
      #
      # Sends one notification to a subscriber, recording the message id so a Reset in
      # reply (RFC 7641 §4.5) can identify the entry.
      #
      # @param subscriber [Hash] subscription entry with `:address`, `:port`, `:token`
      #   and an optional `:transport`/`:content_format`
      # @param value [Object] value to notify; stringified for the wire
      # @param code [String] the notification's CoAP response code
      # @param observe [Integer, nil] sequence value for the Observe option
      # @return [Takagi::Message::Outbound, nil] the sent message, or nil on error
      def send_packet(subscriber, value, code: '2.05 Content', observe: nil)
        transport = subscriber[:transport] || @transport
        message = notification(subscriber, value, transport, code: code, observe: observe)
        @sender.transmit(message, subscriber[:address], subscriber[:port])
        message
      rescue StandardError => e
        Takagi.logger.error "Observer Notify Error: #{e.message}"
        nil
      end

      # Builds the CoAP notification message for one subscriber value. A 2.xx notification
      # carries the Observe option when `observe:` is given and echoes the subscriber's
      # Content-Format; a non-2.xx notification (an ended observation) carries no Observe
      # option (RFC 7641 §4.2). The message type derives from the pub/sub binding for the
      # underlying transport (NON by default, none over a reliable transport).
      #
      # @param subscriber [Hash] subscription entry with `:token`, `:content_format`
      # @param value [Object] value to notify; stringified for the wire
      # @param transport [Symbol] transport the notification travels over
      # @param code [String] the notification's CoAP response code
      # @param observe [Integer, nil] sequence value for the Observe option
      # @return [Takagi::Message::Outbound]
      def notification(subscriber, value, transport = @transport, code: '2.05 Content', observe: nil)
        payload = value.to_s.b
        block = first_block(payload)
        options = {}
        options.merge!(block_options(block, payload)) if block
        options[CoAP::Registries::Option::CONTENT_FORMAT] = [subscriber[:content_format]] if subscriber[:content_format]
        options[CoAP::Registries::Option::OBSERVE] = [observe] if observe && code.to_s.start_with?('2.')

        Takagi::Message::Outbound.new(
          code: code,
          payload: block ? block.payload : payload,
          token: subscriber[:token],
          message_id: rand(0..0xFFFF),
          type: notification_type(transport),
          transport: transport,
          options: options
        )
      end

      private

      # The CoAP message type of a notification for a transport, per the binding's
      # declaration: NON by default, none over a reliable transport (RFC 8323 §3).
      #
      # @param transport [Symbol]
      # @return [Integer, nil]
      def notification_type(transport)
        PubSub::CoapObserve.for(transport || :udp).notification_type
      end

      # The first block of a representation that does not fit one datagram, or nil when
      # block-wise transfer is disabled or the value fits one block.
      #
      # @param payload [String] the whole representation
      # @return [Takagi::CoAP::BlockWise::Block, nil]
      def first_block(payload)
        settings = block_wise_settings
        return nil unless settings&.enabled

        szx = (settings.szx || CoAP::BlockWise::OptionValue::MAX_SZX).to_i
        return nil if payload.bytesize <= CoAP::BlockWise::OptionValue.size_for(szx)

        CoAP::BlockWise.slice(payload, szx: szx).first
      end

      # Block2, Size2 and a per-representation ETag, as {Takagi::Middleware::BlockWise}
      # sets them on the first block of a sliced response.
      #
      # @param block [Takagi::CoAP::BlockWise::Block] the first block
      # @param payload [String] the whole representation the ETag and Size2 describe
      # @return [Hash] CoAP options { option_number => [value] }
      def block_options(block, payload)
        {
          CoAP::Registries::Option::BLOCK2 => [block.option_value],
          CoAP::Registries::Option::ETAG => [Digest::SHA256.digest(payload).byteslice(0, 8)],
          CoAP::Registries::Option::SIZE2 => [uint_bytes(payload.bytesize)]
        }
      end

      # @return [Object, nil] the configured `block_wise` settings
      def block_wise_settings
        Takagi.config.block_wise if Takagi.config.respond_to?(:block_wise)
      end

      # Minimal big-endian encoding for a uint option value (Size2).
      #
      # @param value [Integer]
      # @return [String]
      def uint_bytes(value)
        bytes = [value.to_i].pack('N').bytes
        bytes.shift while bytes.length > 1 && bytes.first.zero?
        bytes.pack('C*')
      end
    end
  end
end
