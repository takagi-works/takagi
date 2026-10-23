# frozen_string_literal: true

require 'io/wait'

module Takagi
  class Bus
    module AsyncExecutor
      # Thread-based executor that keeps each subscriber ordered.
      #
      # A subscriber owns ONE in-flight slot and one ordered backlog, so its
      # messages are delivered in the order they were posted and it never runs
      # concurrently with itself. `size` bounds how many DIFFERENT subscribers
      # may run at once; ordering is not obtained by making it 1.
      #
      # Each subscriber's backlog is bounded ({DEFAULT_BACKLOG_LIMIT}); a post
      # that would exceed the bound is refused and logged, naming the subscriber.
      class ThreadExecutor
        DEFAULT_BACKLOG_LIMIT = 1024

        attr_reader :size, :backlog_limit

        def initialize(size:, backlog_limit: DEFAULT_BACKLOG_LIMIT)
          @size = size.positive? ? size : 1
          @backlog_limit = backlog_limit.positive? ? backlog_limit : 1
          @queue = Queue.new
          @threads = []
          @mutex = Mutex.new
          @backlogs = {}
          @in_flight = {}
          @refused = 0
          @shutdown = false
          start_workers
        end

        # Queue one message for one subscriber.
        #
        # @return [Boolean] false when that subscriber's backlog is full and the
        #   message was refused
        def post(handler, message) # rubocop:disable Naming/PredicateMethod -- refusal is reported by returning false
          refused = @mutex.synchronize do
            raise 'Executor is shutdown' if @shutdown

            backlog = (@backlogs[handler] ||= [])
            if backlog.size >= @backlog_limit
              @refused += 1
              true
            else
              backlog << message
              promote(handler)
              false
            end
          end

          log_refusal(handler) if refused
          !refused
        end

        # Per-handler state is created by the first `post`; nothing to register.
        def register_handler(_handler); end

        # Work already accepted stays deliverable after a subscriber unregisters,
        # as it did before; the drain drops the entry once the backlog is empty.
        def unregister_handler(_handler); end

        def shutdown
          already_shutdown = @mutex.synchronize do
            if @shutdown
              true
            else
              @shutdown = true
              @size.times { @queue << nil }
              false
            end
          end
          return if already_shutdown

          @threads.each(&:join)
          @threads.clear
        end

        def running?
          !@shutdown
        end

        def stats
          @mutex.synchronize do
            {
              mode: :threads,
              size: @size,
              backlog_limit: @backlog_limit,
              in_flight: @in_flight.size,
              queued: @backlogs.sum { |_handler, backlog| backlog.size },
              refused: @refused
            }
          end
        end

        private

        # The in-flight slot is what orders a subscriber: the first message of a
        # burst hands it to a worker, and every later one only joins the backlog
        # that the running worker drains.
        def promote(handler)
          return if @in_flight[handler]

          @in_flight[handler] = true
          @queue << handler
        end

        def start_workers
          @size.times do |index|
            @threads << Thread.new do
              Thread.current.name = "EventBus-ThreadExecutor-#{index}"
              worker_loop
            end
          end
        end

        def worker_loop
          loop do
            handler = @queue.pop
            break if handler.nil?

            drain(handler)
          end
        end

        # Run one subscriber's backlog to exhaustion before releasing its
        # in-flight slot, so a message posted while it runs joins the backlog the
        # running worker is already consuming instead of starting a second worker
        # on the same subscriber.
        def drain(handler)
          loop do
            message = @mutex.synchronize do
              backlog = @backlogs[handler]
              if backlog.nil? || backlog.empty?
                @backlogs.delete(handler)
                @in_flight.delete(handler)
                nil
              else
                backlog.shift
              end
            end
            break if message.nil?

            deliver(handler, message)
          end
        end

        def deliver(handler, message)
          handler.call(message)
        rescue StandardError => e
          warn "EventBus ThreadExecutor error: #{e.class} - #{e.message}"
        end

        def log_refusal(handler)
          message = "Bus async backlog full (#{@backlog_limit}) for subscriber " \
                    "#{handler.address} (#{handler.consumer_id}); message refused"
          if defined?(Takagi.logger)
            Takagi.logger.warn(message)
          else
            warn(message)
          end
        end
      end
    end
  end
end
