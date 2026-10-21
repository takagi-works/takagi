# frozen_string_literal: true

require_relative '../response_builder'
require_relative '../message/deduplication_cache'

module Takagi
  module Server
    # Handles incoming UDP messages on behalf of the master Udp server.
    class UdpWorker # rubocop:disable Metrics/ClassLength -- the bounded drain must live with the reader-thread lifecycle it drains (spawn, sentinel, join); moving it out would split the drain from the threads it ends, and splitting this class is a separate refactor
      RECV_BUFFER_SIZE = 65_535

      # How long in-flight datagram work may take to finish once the receive loop has stopped
      # accepting: the datagrams already received are handled and the reader threads are joined
      # INSIDE this deadline, and a handler still running at it is signalled rather than waited
      # on. This is the deadline this transport DECLARES (`Udp::DRAIN_DEADLINE` is this same
      # value, handed to the cluster as the adapter's `drain_deadline`) and the INNER half of the
      # drain contract: the master's batch deadline, `Cluster::WORKER_TERM_TIMEOUT` (2.0 s), is
      # strictly larger, so the KILL that escorts a child out cannot preempt a drain still
      # inside it.
      DRAIN_DEADLINE = 1.0

      # The sentinel the drain pushes once per reader thread to end it. A datagram is always the
      # `[data, addr]` pair the receive loop pushed, so a bare symbol can never be one.
      DRAIN_SENTINEL = :drain

      def initialize(socket:, middleware_stack:, **options)
        @socket = socket
        @middleware_stack = middleware_stack
        @router = options.fetch(:router, nil)
        @sender = options.fetch(:sender)
        @logger = options.fetch(:logger)
        @port = options.fetch(:port)
        @bind_address = options.fetch(:bind_address, '0.0.0.0')
        @threads = options.fetch(:threads)
        @drain_deadline = options.fetch(:drain_deadline, DRAIN_DEADLINE)
        @stop_requested = options.fetch(:stop_requested, nil)
        @recv_buffer_size = options.fetch(:recv_buffer_size, RECV_BUFFER_SIZE)
        @dedup_cache = Takagi::Message::DeduplicationCache.new
      end

      def run
        @shutdown = false

        # No signal traps here on purpose. The cluster owns TERM/INT on every shipped path (its
        # own trap armed in a child from the pre-fork master pid), and a later trap REPLACES an
        # earlier one - Ruby does not chain handlers. A trap installed here would therefore
        # disarm the cluster's stop flag in a child that serves SEVERAL transports, leaving every
        # OTHER adapter of that child unable to see the stop at all and needing the master's KILL.
        # This worker stops when its driver says so (#stop_requested?, which carries the cluster's
        # flag and the parent-death guard) or when @shutdown is set for it.
        @queue = Queue.new
        @readers = Array.new(@threads) { spawn_thread(@queue) }

        @logger.debug "[Worker PID: #{Process.pid}] Listening on CoAP://#{@bind_address}:#{@port} with #{@threads} threads"
        process_loop(@queue)
      ensure
        # This loop's end IS the stop path, so the drain runs here: the receive loop has
        # stopped accepting (it returned, or the socket went away under it), so the datagrams
        # already received are handled and the readers are joined before control returns to
        # the cluster - which is what lets a response survive a stop that arrives mid-handler
        # instead of dying with the process.
        drain
      end

      # The bounded drain: one sentinel per reader, pushed AFTER whatever the receive loop
      # already queued, so the queued datagrams are handled first and every reader ends on the
      # sentinel; then the readers are joined inside DRAIN_DEADLINE and a straggler is signalled
      # at it. Idempotent (the handles are taken), and bounded on purpose: a client that never
      # releases its exchange cannot hold the stop open past the deadline.
      def drain
        queue = @queue
        readers = @readers
        @queue = nil
        @readers = nil
        return unless queue && readers

        readers.size.times { queue << DRAIN_SENTINEL }
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @drain_deadline
        readers.each do |reader|
          reader.join([deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0].max)
          next unless reader.alive?

          @logger.warn "[Worker PID: #{Process.pid}] drain deadline (#{@drain_deadline} s) reached; " \
                       'signalling a handler still in flight'
          reader.kill
        end
      end

      private

      # The receiver loop, run until the driver asks it to stop. It RETURNS rather than
      # exiting: at a count of 1 the cluster runs this loop in the server's own process, so
      # `exit` would end the whole server instead of the loop, and above 1 the forked child
      # exits by itself once this returns (Cluster#fork_worker).
      def process_loop(queue)
        until stop_requested?
          next unless @socket.wait_readable(0.1)

          datagram = receive_datagram
          queue << datagram if datagram
        end
        @logger.debug "[Worker PID: #{Process.pid}] Shutting down..."
      rescue Interrupt, SignalException
        @logger.debug "[Worker PID: #{Process.pid}] Interrupted, shutting down..."
      rescue IOError => e
        # Another thread closed this socket while this loop waited on it - the server's own
        # shutdown does, at a count of 1 in this very process. Nothing is left to receive, so
        # the loop ends the way a stop ends it.
        @logger.debug "[Worker PID: #{Process.pid}] Socket closed (#{e.class}: #{e.message}), shutting down..."
      end

      def receive_datagram
        data, addr = @socket.recvfrom_nonblock(@recv_buffer_size)
        if data.bytesize >= @recv_buffer_size
          @logger.warn "[Worker PID: #{Process.pid}] Datagram may be truncated " \
                       "(received #{data.bytesize} bytes into a #{@recv_buffer_size}-byte buffer)"
        end
        [data, addr]
      rescue IO::WaitReadable
        # NON-blocking on purpose: several workers share this listening socket, so the
        # readiness `wait_readable` just reported can be consumed by a sibling before this
        # read runs. A BLOCKING read would then park this worker inside recvfrom(2) - past the
        # stop flag it cannot re-check - and only the master's KILL could end it, which no
        # drain deadline survives. Losing the race means no datagram for this pass; the
        # loop's next wait_readable picks up whatever is still buffered. No datagram is
        # dropped and nothing about handling changes.
        nil
      end

      # True once this worker must wind its loop down: the driver that armed it asked (the
      # cluster - whose parent-death guard is armed with the master pid captured BEFORE the
      # fork), or a signal did. The worker never asks the kernel for its parent pid itself:
      # a child first scheduled after its master's death reads the REAPER as its parent and
      # would serve forever on the inherited socket, the race this delegation removes.
      def stop_requested?
        @shutdown || driver_stop_requested?
      end

      # The stop state of whatever drives this loop; false when nothing does, in which case
      # only this worker's own traps end it.
      def driver_stop_requested? = !@stop_requested.nil? && @stop_requested.call

      def spawn_thread(queue)
        Thread.new do
          loop do
            request, addr = queue.pop
            break if request == DRAIN_SENTINEL

            handle_request(request, addr)
          end
        end
      end

      def handle_request(request, addr)
        inbound_request = Takagi::Message::Inbound.new(request)
        log_inbound_request(inbound_request)

        # RFC 7252 §4.5: Check for duplicate messages
        source_endpoint = "#{addr[3]}:#{addr[1]}"
        if inbound_request.type.zero? # CON message
          cached_response = @dedup_cache.check_duplicate(inbound_request.message_id, source_endpoint)
          if cached_response
            @logger.debug "Duplicate CON detected (MID: #{inbound_request.message_id}), resending cached response"
            return @sender.transmit(cached_response, addr[3], addr[1])
          end
        end

        immediate = immediate_response(inbound_request, request)
        if immediate
          @dedup_cache.store_response(inbound_request.message_id, source_endpoint, immediate.to_bytes) if inbound_request.type.zero?
          return transmit(immediate, addr)
        end

        return unless routable_request?(inbound_request)

        # Delegate to controller's thread pool if available
        delegate_to_controller_pool(inbound_request, addr)
      rescue Takagi::Message::ParseError => e then @logger.debug "Ignoring malformed datagram from #{addr[3]}:#{addr[1]}: #{e.inspect}"
      rescue StandardError => e
        @logger.error "Handle_request failed: #{e.message}"
      end

      def delegate_to_controller_pool(inbound_request, addr)
        # Find which controller handles this path
        path = inbound_request.uri.path
        controller_class = find_controller_for_path(path)

        if controller_class&.workers_running?
          # Delegate to controller's thread pool
          @logger.debug "Delegating #{path} to #{controller_class.name} worker pool"
          source_endpoint = "#{addr[3]}:#{addr[1]}"

          controller_class.schedule do
            process_request(inbound_request, addr, source_endpoint)
          end
        else
          # No pool running IN THIS PROCESS - either none was started, or this worker was
          # forked after the parent started one, in which case the pool's threads died with
          # the fork and its queue has no drainer. Process synchronously (backward
          # compatible), so the client always gets a response.
          @logger.debug "Processing #{path} synchronously (no controller pool in this process)"
          source_endpoint = "#{addr[3]}:#{addr[1]}"
          process_request(inbound_request, addr, source_endpoint)
        end
      end

      def process_request(inbound_request, addr, source_endpoint)
        result = @middleware_stack.call(inbound_request)
        log_middleware_result(result)
        response = build_response(inbound_request, result)

        # Cache CON responses for duplicate detection
        if inbound_request.type.zero? && response
          response_data = response.to_bytes
          @dedup_cache.store_response(inbound_request.message_id, source_endpoint, response_data)
        end

        transmit(response, addr)
      rescue StandardError => e
        @logger.error "Process_request failed: #{e.message}"
      end

      def find_controller_for_path(path)
        # If using a CompositeRouter, find the controller
        # Otherwise return nil (backward compatible with single Router)
        return nil unless @router&.respond_to?(:find_controller_for_path)

        @router.find_controller_for_path(path)
      end

      def log_inbound_request(inbound_request)
        @logger.debug "Code: #{inbound_request.code}"
        @logger.debug "Method: #{inbound_request.method}"
      end

      def immediate_response(inbound_request, datagram = nil)
        if inbound_request.version != 1
          log_ignored_datagram(inbound_request, 'unknown version')
          return nil
        end

        if [CoAP::Registries::MessageType::ACK, CoAP::Registries::MessageType::RST].include?(inbound_request.type)
          log_ignored_datagram(inbound_request, 'response')
          return nil
        end

        rejectable = format_error?(inbound_request, datagram) || inbound_request.code.zero?
        reset_response(inbound_request) if rejectable
      end

      def reset_response(inbound_request)
        Takagi::Message::Outbound.new(
          code: '0.00',
          payload: '',
          token: '',
          message_id: inbound_request.message_id,
          type: CoAP::Registries::MessageType::RST
        )
      end

      def format_error?(inbound_request, datagram)
        return true if datagram.is_a?(String) && !datagram.empty? && (datagram.getbyte(0) & 0b1111).between?(9, 15)
        return false unless inbound_request.code.zero?

        !inbound_request.token.empty? || (datagram.is_a?(String) && datagram.bytesize > 4)
      end

      def routable_request?(inbound_request)
        inbound_request.version == 1 &&
          [CoAP::Registries::MessageType::CON, CoAP::Registries::MessageType::NON].include?(inbound_request.type)
      end

      def log_ignored_datagram(inbound_request, reason)
        @logger.debug "Ignoring #{reason} datagram (type: #{inbound_request.type}, " \
                      "code: #{inbound_request.code}, MID: #{inbound_request.message_id})"
      end

      def log_middleware_result(result)
        @logger.debug "Middleware result class: #{result.class}"
        @logger.debug "Middleware result inspect: #{result.inspect}"
        return unless result.is_a?(Hash)

        @logger.debug "Hash response keys: #{result.keys}"
        result.each do |key, value|
          @logger.debug "Key: #{key.inspect} => #{value.inspect} (#{value.class})"
        end
      end

      def build_response(inbound_request, result)
        ResponseBuilder.build(inbound_request, result, logger: @logger)
      end

      def transmit(response, addr)
        @sender.transmit(response, addr[3], addr[1])
      end
    end
  end
end
