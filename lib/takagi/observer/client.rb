# frozen_string_literal: true

require 'uri'
require 'socket'
require 'securerandom'
require_relative '../network/udp_socket'

module Takagi
  module Observer
    # RFC 7641 observing client used by the integration examples and reactors.
    #
    # The subscription verdict is read from the Observe option of the registration response
    # (RFC 7641 §4.1): its presence confirms the subscription, and the response - carrying the
    # current state - is delivered as the initial notification; its absence reports a failed
    # subscription and is never delivered as a notification. Incoming notifications follow
    # the freshness rule of §3.4: a notification that is not fresher does not replace the
    # current state. {#cancel} deregisters with a GET carrying Observe: 1 (RFC 7641 §3.6)
    # and a Reset on the last notification where the transport carries it (§4.5).
    class Client
      RECV_BUFFER_SIZE = 65_535

      # The token of this observation, echoed by every notification.
      attr_reader :token

      # The sequence value of the last accepted notification (nil until one arrives).
      attr_reader :last_seq

      def initialize(uri, recv_buffer_size: RECV_BUFFER_SIZE)
        @uri = URI.parse(uri)
        @token = SecureRandom.hex(4)
        @socket = Takagi::Network::UdpSocket.for(@uri.hostname)
        @on_notify = nil
        @on_subscription_failed = nil
        @recv_buffer_size = recv_buffer_size
        @subscribed = false
        @last_seq = nil
        @last_mid = nil
      end

      def on_notify(&block)
        @on_notify = block
      end

      # Called with the registration response when it carries no Observe option: the
      # subscription failed (RFC 7641 §4.1) and the client stops delivering.
      def on_subscription_failed(&block)
        @on_subscription_failed = block
      end

      # Registers and returns the subscription verdict once the first matching response
      # arrives: `:subscribed` when it carried the Observe option, `:failed` when not.
      #
      # @return [Symbol] :subscribed or :failed
      def subscribe
        send_observe_request
        @running = true
        @verdict = Queue.new
        @thread = Thread.new { handle_notification_iteration while @running }
        @verdict.pop
      end

      # Ends the observation: a GET with the observation's token and Observe: 1, plus a
      # Reset on the last notification (which the datagram transport carries).
      #
      # @return [void]
      def cancel
        send_deregistration
        stop
      end

      def stop
        @running = false
        @socket.close unless @socket.closed?
      end
      alias close stop

      private

      def send_observe_request
        message = Takagi::Message::Request.new(
          method: :get,
          uri: @uri,
          token: @token,
          observe: 0
        )
        @socket.send(message.to_bytes, 0, @uri.hostname, @uri.port || 5683)
      end

      def send_deregistration
        message = Takagi::Message::Request.new(method: :get, uri: @uri, token: @token, observe: 1)
        @socket.send(message.to_bytes, 0, @uri.hostname, @uri.port || 5683)

        return unless @last_mid

        reset = Takagi::Message::Outbound.new(
          code: '0.00',
          payload: '',
          token: '',
          message_id: @last_mid,
          type: Takagi::CoAP::Registries::MessageType::RST
        )
        @socket.send(reset.to_bytes, 0, @uri.hostname, @uri.port || 5683)
      end

      def handle_notification_iteration
        data, _addr = @socket.recvfrom_nonblock(@recv_buffer_size)
        if data.bytesize >= @recv_buffer_size
          Takagi.logger.warn "Observer notify datagram may be truncated (#{data.bytesize} bytes into a #{@recv_buffer_size}-byte buffer)"
          return
        end

        inbound = Takagi::Message::Inbound.new(data)
        return unless inbound.token == @token

        @subscribed ? dispatch_notification(inbound) : decide_verdict(inbound)
      rescue IO::WaitReadable
        # A stop from another thread (close of the socket this thread waits on) surfaces as
        # an IOError from the wait itself; it is not a wait for data, so end the listener
        # instead of retrying into a closed socket.
        begin
          @socket.wait_readable
        rescue IOError
          @running = false
        end
        retry
      rescue IOError
        @running = false
      end

      def decide_verdict(inbound)
        @last_mid = inbound.message_id
        if inbound.option?(Takagi::CoAP::Registries::Option::OBSERVE)
          @subscribed = true
          @verdict.push(:subscribed)
          dispatch_notification(inbound)
        else
          @verdict.push(:failed)
          @on_subscription_failed&.call(inbound)
          stop
        end
      end

      def dispatch_notification(inbound)
        @last_mid = inbound.message_id

        sequence = observe_value(inbound)
        return if stale?(sequence)

        @last_seq = sequence unless sequence.nil?

        payload = inbound.payload
        payload = payload.split("\xFF", 2).last if payload&.include?("\xFF")
        payload = payload&.dup&.force_encoding('UTF-8')
        Takagi.logger.info "Received notify: #{payload}"
        @on_notify&.call(payload, inbound)
      end

      # The freshness rule of RFC 7641 §3.4: a notification that is not fresher than the one
      # already accepted does not replace the current state.
      def stale?(candidate)
        return false if candidate.nil? || @last_seq.nil?

        !fresher?(candidate, @last_seq)
      end

      def fresher?(candidate, last)
        diff = (candidate - last) % (1 << 24)
        !diff.zero? && diff < (1 << 23)
      end

      def observe_value(inbound)
        raw = Array(inbound.options[Takagi::CoAP::Registries::Option::OBSERVE]).first
        return nil unless raw

        raw.to_s.b.bytes.reduce(0) { |acc, byte| (acc << 8) | byte }
      end
    end
  end
end
