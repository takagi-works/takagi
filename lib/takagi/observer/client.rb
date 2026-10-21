# frozen_string_literal: true

require 'uri'
require 'socket'
require 'securerandom'
require_relative '../network/udp_socket'

module Takagi
  module Observer
    # Lightweight CoAP observe client for integration testing.
    class Client
      RECV_BUFFER_SIZE = 65_535

      def initialize(uri, recv_buffer_size: RECV_BUFFER_SIZE)
        @uri = URI.parse(uri)
        @token = SecureRandom.hex(4)
        @socket = Takagi::Network::UdpSocket.for(@uri.hostname)
        @on_notify = nil
        @recv_buffer_size = recv_buffer_size
      end

      def on_notify(&block)
        @on_notify = block
      end

      def subscribe
        send_observe_request
        listen_for_notifications
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

      def listen_for_notifications
        @running = true
        @thread = Thread.new { handle_notification_iteration while @running }
      end

      def handle_notification_iteration
        data, _addr = @socket.recvfrom_nonblock(@recv_buffer_size)
        if data.bytesize >= @recv_buffer_size
          Takagi.logger.warn "Observer notify datagram may be truncated (#{data.bytesize} bytes into a #{@recv_buffer_size}-byte buffer)"
          return
        end

        inbound = Takagi::Message::Inbound.new(data)
        return unless inbound.token == @token

        dispatch_notification(inbound)
      rescue IO::WaitReadable
        @socket.wait_readable
        retry
      rescue IOError
        @running = false
      end

      def dispatch_notification(inbound)
        payload = inbound.payload
        payload = payload.split("\xFF", 2).last if payload&.include?("\xFF")
        payload = payload&.dup&.force_encoding('UTF-8')
        Takagi.logger.info "Received notify: #{payload}"
        @on_notify&.call(payload, inbound)
      end
    end
  end
end
