# frozen_string_literal: true

require 'digest'
require_relative '../coap/block_wise'

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
      # @param subscriber [Hash] subscription entry with `:address`, `:port`, `:token`
      #   and an optional `:transport`
      # @param value [Object] value to notify; stringified for the wire
      # @return [void]
      def send_packet(subscriber, value)
        # Get transport from subscriber metadata, or use instance default
        transport = subscriber[:transport] || @transport

        @sender.transmit(notification(subscriber, value, transport), subscriber[:address], subscriber[:port])
      rescue StandardError => e
        Takagi.logger.error "Observer Notify Error: #{e.message}"
      end

      # Builds the CoAP notification message for one subscriber value.
      #
      # The value is sliced with {Takagi::CoAP::BlockWise.slice} — the engine
      # {Takagi::Middleware::BlockWise} slices responses with — when it exceeds one
      # block. Per RFC 7959 §3.4 a notification carries just the first block, with a
      # Block2 option (NUM 0, M 1), the Size2 of the whole representation and an ETag
      # over it; the observer fetches the remaining blocks with further requests. A
      # value that fits one block is sent unchanged, with no Block2 option.
      #
      # @param subscriber [Hash] subscription entry with `:token`
      # @param value [Object] value to notify; stringified for the wire
      # @param transport [Symbol] transport the notification travels over
      # @return [Takagi::Message::Outbound]
      def notification(subscriber, value, transport)
        payload = value.to_s.b
        block = first_block(payload)

        Takagi::Message::Outbound.new(
          code: '2.05',
          payload: block ? block.payload : payload,
          token: subscriber[:token],
          message_id: rand(0..0xFFFF),
          type: 1, # NON
          transport: transport,
          options: block ? block_options(block, payload) : {}
        )
      end

      private

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
