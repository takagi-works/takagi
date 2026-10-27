# frozen_string_literal: true

module Takagi
  # A bounded worker pool used by reactors for their background work.
  #
  # The SERVICE's concurrency is the servers' own pools (`threads` / `processes` in the
  # Application or Takagi configuration); this pool exists for work that is not request
  # serving - observable polling, event delivery, remote observation.
  #
  # @example
  #   pool = ThreadPool.new(size: 4, name: 'sensor-reactor')
  #   pool.schedule { do_work }
  #   pool.shutdown
  class ThreadPool
    attr_reader :size, :name, :stats

    # @param size [Integer] Number of worker threads
    # @param name [String] Pool name for debugging/monitoring
    def initialize(size:, name: 'thread-pool')
      @size = size
      @name = name
      @queue = Queue.new
      @workers = []
      @shutdown = false
      @owner_pid = Process.pid
      @mutex = Mutex.new
      @stats = {
        processed: 0,
        errors: 0,
        queue_size: 0,
        created_at: Time.now
      }

      spawn_workers
    end

    # Schedule a job to be executed by the thread pool
    #
    # @yield Block to execute in a worker thread
    # @raise [RuntimeError] if pool is shutdown
    def schedule(&block)
      raise "ThreadPool '#{@name}' is shutdown" if @shutdown

      @queue << block
      update_queue_size
    end

    # Gracefully shutdown the thread pool
    #
    # Sends poison pills to all workers and waits for them to finish.
    # Blocks until all workers have terminated.
    def shutdown
      return if @shutdown

      @shutdown = true
      @size.times { @queue << nil } # Poison pills
      @workers.each(&:join)
      Takagi.logger.info "ThreadPool '#{@name}' shutdown complete"
    end

    # Check if the pool is shutdown
    #
    # @return [Boolean] true if shutdown
    def shutdown?
      @shutdown
    end

    # Check whether this pool's worker threads live in the calling process
    #
    # The pool OBJECT survives a `fork`; its threads do not. A child that inherited a
    # parent's pool must not schedule into it, so anything delegating to a pool asks this
    # first.
    #
    # @return [Boolean] true when the pool was created by the calling process
    def running_in_this_process?
      @owner_pid == Process.pid
    end

    # Get current pool statistics
    #
    # @return [Hash] Statistics including processed, errors, queue size
    def current_stats
      @mutex.synchronize do
        @stats.merge(
          size: @size,
          queue_size: @queue.size,
          shutdown: @shutdown,
          uptime: Time.now - @stats[:created_at]
        )
      end
    end

    # Get the number of jobs currently in the queue
    #
    # @return [Integer] Queue size
    def queue_size
      @queue.size
    end

    # Check if the queue is empty
    #
    # @return [Boolean] true if queue is empty
    def empty?
      @queue.empty?
    end

    private

    def spawn_workers
      @size.times do |i|
        @workers << Thread.new do
          Thread.current.name = "#{@name}-worker-#{i}"
          worker_loop
        end
      end

      Takagi.logger.debug "ThreadPool '#{@name}' started with #{@size} workers"
    end

    def worker_loop
      loop do
        job = @queue.pop
        break if job.nil? # Poison pill

        begin
          job.call
          increment_stat(:processed)
        rescue StandardError => e
          increment_stat(:errors)
          Takagi.logger.error "[#{@name}] Worker error: #{e.message}"
          Takagi.logger.debug e.backtrace.join("\n")
        end
      end
    end

    def increment_stat(key)
      @mutex.synchronize { @stats[key] += 1 }
    end

    def update_queue_size
      @mutex.synchronize { @stats[:queue_size] = @queue.size }
    end
  end
end
