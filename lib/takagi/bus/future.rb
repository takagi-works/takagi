# frozen_string_literal: true

require 'timeout'

module Takagi
  class Bus
    # Future for sync/async request-reply pattern (pure Ruby)
    # Uses ConditionVariable for efficient waiting
    #
    # @example Blocking wait
    #   future = Future.new
    #   Thread.new { future.set_value(42) }
    #   value = future.value(timeout: 1.0) # => 42
    #
    # @example Non-blocking check
    #   future = Future.new
    #   future.completed? # => false
    #   future.set_value(42)
    #   future.completed? # => true
    #
    # @example Error propagation
    #   future = Future.new
    #   future.set_error(StandardError.new("Failed"))
    #   future.value # raises StandardError
    class Future
      # Initialize a new Future
      def initialize
        @mutex = Mutex.new
        @condition = ConditionVariable.new
        @value = nil
        @completed = false
        @error = nil
      end

      # Set the successful value of the Future
      # @param value [Object] The value to set
      # @raise [RuntimeError] If already completed
      def set_value(value)
        @mutex.synchronize do
          raise 'Future already completed' if @completed

          @value = value
          @completed = true
          @condition.broadcast
        end
      end

      # Set the error state of the Future
      # @param error [Exception] The error to set
      # @raise [RuntimeError] If already completed
      def set_error(error)
        @mutex.synchronize do
          raise 'Future already completed' if @completed

          @error = error
          @completed = true
          @condition.broadcast
        end
      end

      # Get the value of the Future (blocking)
      # @param timeout [Float, nil] Timeout in seconds (nil = wait forever)
      # @return [Object] The value
      # @raise [Timeout::Error] If timeout expires before completion
      # @raise [Exception] The error if Future completed with error
      def value(timeout: nil) # rubocop:disable Metrics/PerceivedComplexity
        @mutex.synchronize do
          unless @completed
            if timeout
              # Wait with timeout
              deadline = Time.now + timeout
              while !@completed && Time.now < deadline
                remaining = deadline - Time.now
                break if remaining <= 0

                @condition.wait(@mutex, remaining)
              end

              raise Timeout::Error, "Future timed out after #{timeout}s" unless @completed
            else
              # Wait indefinitely
              @condition.wait(@mutex) until @completed
            end
          end

          # Raise error if set
          raise @error if @error

          # Return value
          @value
        end
      end

      # Check if Future is completed
      # @return [Boolean]
      def completed?
        @mutex.synchronize { @completed }
      end

      # Check if Future completed with error
      # @return [Boolean]
      def error?
        @mutex.synchronize { @completed && !@error.nil? }
      end

      # Check if Future completed successfully
      # @return [Boolean]
      def success?
        @mutex.synchronize { @completed && @error.nil? }
      end

      # Get the error if present
      # @return [Exception, nil]
      def error
        @mutex.synchronize { @error }
      end

      # Try to get value without blocking
      # @return [Object, nil] Value if completed, nil otherwise
      def try_value
        @mutex.synchronize do
          return nil unless @completed
          raise @error if @error

          @value
        end
      end

      # Wait for completion without returning value
      # @param timeout [Float, nil] Timeout in seconds
      # @return [Boolean] True if completed, false if timeout
      def wait(timeout: nil)
        @mutex.synchronize do
          return true if @completed

          if timeout
            deadline = Time.now + timeout
            while !@completed && Time.now < deadline
              remaining = deadline - Time.now
              break if remaining <= 0

              @condition.wait(@mutex, remaining)
            end
          else
            @condition.wait(@mutex) until @completed
          end

          @completed
        end
      end
    end
  end
end
