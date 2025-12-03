# frozen_string_literal: true

require 'socket'
require 'timeout'
require_relative 'udp_worker'

module Takagi
  module Server
    # UDP server for handling CoAP messages
    class Udp
      def initialize(port: 5683, worker_processes: 2, worker_threads: 2,
                     middleware_stack: nil, router: nil, logger: nil, watcher: nil)
        @port = port
        @worker_processes = worker_processes
        @worker_threads = worker_threads
        @middleware_stack = middleware_stack || Takagi::MiddlewareStack.instance
        @router = router || Takagi::Router.instance
        @logger = logger || Takagi.logger
        @watcher = watcher || Takagi::Observer::Watcher.new(interval: 1)

        Initializer.run!

        @socket = UDPSocket.new
        @socket.bind('0.0.0.0', @port)
        Takagi::Network::UdpSender.instance.setup(socket: @socket)
        @sender = Takagi::Network::UdpSender.instance
      end

      # Starts the server with multiple worker processes
      def run!
        Takagi::Hooks.emit(:server_starting, protocol: :udp, port: @port)
        log_boot_details
        spawn_workers
        Takagi::Observable::Registry.start_all
        @watcher.start

        # Set flag instead of calling shutdown! directly from trap context
        # This avoids "can't be called from trap context" errors with logger
        trap('INT') { @shutdown_requested = true }

        # Wait for workers with periodic checks for shutdown
        until @shutdown_called || @shutdown_requested
          sleep 0.1
        end

        # Call shutdown if it was requested by signal
        shutdown! if @shutdown_requested
      end

      # Gracefully shuts down all workers
      def shutdown!
        return if @shutdown_called

        @shutdown_called = true
        @watcher.stop
        close_socket
        terminate_workers
        Takagi::Observable::Registry.stop_all

        # Join the server thread if it was spawned
        if defined?(@server_thread) && @server_thread&.alive?
          @server_thread.join(5) # Wait up to 5 seconds
        end

        exit(0) unless test_environment?
        Takagi::Hooks.emit(:server_stopped, protocol: :udp, port: @port)
      end

      private

      def log_boot_details
        @logger.info "Starting Takagi server with #{@worker_processes} processes and #{@worker_threads} threads per process..."
        @logger.info "Takagi server has version #{Takagi::VERSION} with name '#{Takagi::NAME}'"
        @logger.debug "run #{@router.all_routes}"
      end

      def spawn_workers
        @worker_pids = Array.new(@worker_processes) do
          @logger.debug "process with #{@router.all_routes}"
          fork_worker
        end
      end

      def fork_worker
        fork do
          Process.setproctitle('takagi-worker')
          UdpWorker.new(**worker_configuration).run
        end
      end

      def worker_configuration
        {
          port: @port,
          socket: @socket,
          middleware_stack: @middleware_stack,
          router: @router,
          sender: @sender,
          logger: @logger,
          threads: @worker_threads
        }
      end

      def close_socket
        return unless @socket && !@socket.closed?

        @socket.close
      rescue StandardError
        nil
      end

      def terminate_workers
        return unless @worker_pids.is_a?(Array)

        @worker_pids.each do |pid|
          Process.kill('TERM', pid)
        rescue Errno::ESRCH
          # worker already exited
        end

        # Give workers a moment to shut down gracefully
        deadline = Time.now + 2
        @worker_pids.each do |pid|
          begin
            timeout = [deadline - Time.now, 0].max
            Timeout.timeout(timeout) do
              Process.wait(pid)
            end
          rescue Timeout::Error, Errno::ECHILD, Errno::ESRCH
            # Worker didn't exit in time or already exited
          end
        end
      end

      def test_environment?
        ENV['RACK_ENV'] == 'test' || defined?(RSpec)
      end
    end
  end
end
