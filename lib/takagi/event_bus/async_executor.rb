# frozen_string_literal: true

require 'io/wait'

module Takagi
  class EventBus
    module AsyncExecutor
      # Thread-based executor (default fallback)
      class ThreadExecutor
        attr_reader :size

        def initialize(size:)
          @size = size.positive? ? size : 1
          @queue = Queue.new
          @threads = []
          @shutdown = false
          start_workers
        end

        def post(handler, message)
          raise 'Executor is shutdown' if @shutdown

          @queue << [handler, message]
        end

        def register_handler(_handler); end

        def unregister_handler(_handler); end

        def shutdown
          return if @shutdown

          @shutdown = true
          @size.times { @queue << nil }
          @threads.each(&:join)
          @threads.clear
        end

        def running?
          !@shutdown
        end

        def stats
          { mode: :threads, size: @size }
        end

        private

        def start_workers
          @size.times do |index|
            @threads << Thread.new do
              Thread.current.name = "EventBus-ThreadExecutor-#{index}"
              loop do
                job = @queue.pop
                break if job.nil?

                handler, message = job
                begin
                  handler.call(message)
                rescue StandardError => e
                  warn "EventBus ThreadExecutor error: #{e.class} - #{e.message}"
                end
              end
            end
          end
        end
      end

      # Process-based executor for multi-reactor workloads
      class ProcessExecutor
        Job = Struct.new(:pid, :io, :index)

        def initialize(processes:, threads:)
          @processes = processes.positive? ? processes : 0
          @threads = threads
          @mutex = Mutex.new
          @jobs = []
          @next_index = 0
          @needs_restart = false
        end

        def post(handler, message)
          ensure_running
          dispatch(handler, message)
        end

        # Mark for restart so new handlers are visible in workers
        def register_handler(_handler)
          mark_restart_needed
        end

        def unregister_handler(_handler)
          mark_restart_needed
        end

        def shutdown
          @mutex.synchronize { shutdown_workers }
        end

        def stats
          { mode: :processes, size: @jobs.size }
        end

        private

        def ensure_running
          return if @processes.zero?

          @mutex.synchronize do
            restart_workers_locked if @needs_restart && @jobs.any?
            spawn_workers_locked if @jobs.empty?
          end
        end

        def mark_restart_needed
          @mutex.synchronize do
            @needs_restart = true if @jobs.any?
          end
        end

        def restart_workers_locked
          shutdown_workers
          spawn_workers_locked
        end

        def shutdown_workers
          @jobs.each do |job|
            Marshal.dump([:shutdown], job.io)
          rescue IOError, SystemCallError
            # ignore failures while shutting down
          ensure
            job.io.close unless job.io.closed?
            begin
              Process.kill('TERM', job.pid)
            rescue Errno::ESRCH, Errno::EPERM
              nil
            end
            begin
              Process.waitpid(job.pid)
            rescue Errno::ECHILD
              nil
            end
          end
          @jobs.clear
        end

        def spawn_workers_locked
          return if @processes.zero?

          @jobs = Array.new(@processes) { |index| fork_worker(index) }
          @next_index = 0
          @needs_restart = false
        end

        def fork_worker(index)
          reader, writer = IO.pipe

          pid = fork do
            writer.close
            run_worker(reader, index)
            exit! 0
          end

          reader.close
          writer.binmode
          Job.new(pid, writer, index)
        end

        def run_worker(reader, index)
          Signal.trap('TERM') { exit! 0 }
          reader.binmode
          loop do
            payload = Marshal.load(reader) # rubocop:disable Security/MarshalLoad
            type = payload[0]
            case type
            when :shutdown
              break
            when :job
              pool_id = payload[1]
              message = payload[2]
              handler = Takagi::EventBus.handler_for_pool_id(pool_id)
              handler&.call(message)
            end
          rescue EOFError, Errno::EPIPE
            break
          rescue StandardError => e
            warn "EventBus ProcessExecutor[#{index}] error: #{e.class} - #{e.message}"
          end
        end

        def dispatch(handler, message)
          pool_id = handler.respond_to?(:pool_id) ? handler.pool_id : nil
          if pool_id.nil? || @jobs.empty?
            handler.call(message)
            return
          end

          job = select_job
          payload = [:job, pool_id, message]
          begin
            Marshal.dump(payload, job.io)
          rescue Errno::EPIPE, IOError
            @mutex.synchronize do
              reopen_worker(job.index)
            end
            handler.call(message)
          end
        end

        def select_job
          @mutex.synchronize do
            job = @jobs[@next_index % @jobs.size]
            @next_index = (@next_index + 1) % @jobs.size
            job
          end
        end

        def reopen_worker(index)
          old = @jobs[index]
          begin
            old.io.close unless old.io.closed?
          rescue IOError, SystemCallError
            nil
          end
          begin
            Process.waitpid(old.pid)
          rescue Errno::ECHILD
            nil
          end
          @jobs[index] = fork_worker(index)
        end
      end
    end
  end
end
