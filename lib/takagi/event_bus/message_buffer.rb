# frozen_string_literal: true

module Takagi
  class EventBus
    # Bounded message buffer for distributed addresses
    # Stores recent messages in a ring buffer per address for replay on reconnection
    #
    # Features:
    # - Bounded memory (max messages per address)
    # - TTL-based expiration
    # - Thread-safe
    # - Zero external dependencies
    # - Only buffers distributed addresses
    #
    # @example
    #   buffer = MessageBuffer.new(max_messages: 100, ttl: 300)
    #   buffer.store(address, message)
    #   messages = buffer.replay(address, since: Time.now - 60)
    class MessageBuffer
      # Ring buffer for a single address
      class RingBuffer
        def initialize(max_size)
          @max_size = max_size
          @messages = []
          @mutex = Mutex.new
        end

        def push(message)
          @mutex.synchronize do
            @messages.push(message)
            @messages.shift if @messages.size > @max_size # FIFO eviction
          end
        end

        def messages_since(timestamp = nil)
          @mutex.synchronize do
            return @messages.dup unless timestamp

            @messages.select { |msg| msg.timestamp > timestamp }
          end
        end

        def all_messages
          @mutex.synchronize { @messages.dup }
        end

        def size
          @mutex.synchronize { @messages.size }
        end

        def clear
          @mutex.synchronize { @messages.clear }
        end

        def empty?
          size.zero?
        end

        # Clean expired messages based on TTL
        def clean_expired(ttl)
          @mutex.synchronize do
            cutoff = Time.now - ttl
            @messages.reject! { |msg| msg.timestamp < cutoff }
          end
        end
      end

      # @param max_messages [Integer] Maximum messages per address (default: 100)
      # @param ttl [Integer] Time-to-live in seconds (default: 300 = 5 minutes)
      def initialize(max_messages: 100, ttl: 300)
        @max_messages = max_messages
        @ttl = ttl
        @buffers = Hash.new { |h, k| h[k] = RingBuffer.new(@max_messages) }
        @mutex = Mutex.new
        @enabled = true

        start_cleanup_thread
      end

      # Store a message in the buffer
      #
      # @param address [String] Event address
      # @param message [Message] Event message
      def store(address, message)
        return unless @enabled

        @mutex.synchronize do
          @buffers[address].push(message)
        end
      end

      # Store a failed delivery for retry
      # Used by CoAPBridge when network delivery fails
      #
      # @param address [String] Event address
      # @param message [Message] Event message
      # @param destination [String] Failed destination (for logging)
      def store_failed(address, message, destination = nil)
        return unless @enabled

        # Add failure metadata to headers (immutable, so create new message)
        headers = message.headers.dup
        headers[:failed_at] = Time.now
        headers[:failed_destination] = destination if destination

        failed_message = Message.new(
          message.address,
          message.body,
          headers: headers,
          reply_address: message.reply_address
        )

        store(address, failed_message)
      end

      # Replay messages for an address since a given timestamp
      #
      # @param address [String] Event address
      # @param since [Time, nil] Return messages since this time (nil = all messages)
      # @return [Array<Message>] Buffered messages
      #
      # @example Replay last 60 seconds
      #   messages = buffer.replay('sensor.temperature.room1', since: Time.now - 60)
      def replay(address, since: nil)
        @mutex.synchronize do
          return [] unless @buffers.key?(address)

          @buffers[address].messages_since(since)
        end
      end

      # Get all buffered messages for an address
      #
      # @param address [String] Event address
      # @return [Array<Message>] All buffered messages
      def all(address)
        replay(address, since: nil)
      end

      # Get buffer size for an address
      #
      # @param address [String] Event address
      # @return [Integer] Number of buffered messages
      def size(address)
        @mutex.synchronize do
          @buffers[address]&.size || 0
        end
      end

      # Get total number of buffered messages across all addresses
      #
      # @return [Integer] Total buffered messages
      def total_size
        @mutex.synchronize do
          @buffers.values.sum(&:size)
        end
      end

      # Clear buffer for an address
      #
      # @param address [String] Event address
      def clear(address)
        @mutex.synchronize do
          @buffers[address]&.clear
        end
      end

      # Clear all buffers
      def clear_all
        @mutex.synchronize do
          @buffers.clear
        end
      end

      # Enable message buffering
      def enable
        @enabled = true
      end

      # Disable message buffering
      def disable
        @enabled = false
      end

      # Check if buffering is enabled
      def enabled?
        @enabled
      end

      # Get statistics about buffering
      #
      # @return [Hash] Buffer statistics
      def stats
        @mutex.synchronize do
          {
            enabled: @enabled,
            addresses: @buffers.keys.size,
            total_messages: @buffers.values.sum(&:size),
            max_messages_per_address: @max_messages,
            ttl: @ttl,
            buffers: @buffers.transform_values(&:size)
          }
        end
      end

      # Shutdown cleanup thread
      def shutdown
        @cleanup_thread&.kill
        @cleanup_thread = nil
      end

      private

      # Start background thread to clean expired messages
      def start_cleanup_thread
        @cleanup_thread = Thread.new do
          loop do
            sleep [@ttl / 2, 60].min # Clean at least every 60 seconds

            @mutex.synchronize do
              @buffers.each_value do |buffer|
                buffer.clean_expired(@ttl)
              end

              # Remove empty buffers to free memory
              @buffers.delete_if { |_address, buffer| buffer.empty? }
            end
          rescue StandardError => e
            warn "MessageBuffer cleanup error: #{e.message}" if defined?(Takagi.logger)
          end
        end
      end
    end
  end
end
