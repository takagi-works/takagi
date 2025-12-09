# frozen_string_literal: true

require 'securerandom'
require_relative 'event_bus/address_prefix'
require_relative 'event_bus/async_executor'
require_relative 'event_bus/lru_cache'
require_relative 'event_bus/future'
require_relative 'event_bus/coap_bridge'
require_relative 'event_bus/observer_cleanup'
require_relative 'event_bus/message_buffer'
require_relative 'event_bus/scope'

module Takagi
  # High-level event distribution with threaded/process async delivery.
  # Built on top of ObserveRegistry with zero runtime dependencies.
  #
  # Supports both CoAP Observe style and Pub/Sub style APIs:
  #
  # @example CoAP Observe style
  #   EventBus.observe('sensor.temperature.room1') { |msg| puts msg.body }
  #   EventBus.notify('sensor.temperature.room1', { value: 25.5 })
  #
  # @example Pub/Sub style (aliases)
  #   EventBus.consumer('sensor.temperature.room1') { |msg| puts msg.body }
  #   EventBus.publish('sensor.temperature.room1', { value: 25.5 })
  #
  # @example Request-Reply pattern
  #   reply = EventBus.send_sync('cache.query', { key: 'user:123' }, timeout: 1.0)
  class EventBus # rubocop:disable Metrics/ClassLength
    class Error < StandardError; end

    # Event message wrapper (shareable for Ractor)
    class Message
      attr_reader :address, :body, :headers, :reply_address, :timestamp, :scope

      def initialize(address, body, headers: {}, reply_address: nil, scope: Scope::DEFAULT, freeze_body: true)
        @address = address.freeze
        @body = freeze_body ? deep_freeze(body) : body
        @headers = deep_freeze(headers)
        @reply_address = reply_address&.freeze
        @scope = Scope.normalize(scope)
        @timestamp = Time.now
      end

      # Reply to this message (request-reply pattern)
      def reply(body, headers: {})
        return unless @reply_address

        EventBus.publish(@reply_address, body, headers: headers)
      end

      private

      def deep_freeze(obj)
        case obj
        when Hash
          obj.transform_keys(&:freeze).transform_values { |v| deep_freeze(v) }.freeze
        when Array
          obj.map { |v| deep_freeze(v) }.freeze
        else
          # String, Symbol, Numeric, TrueClass, FalseClass, NilClass, and others
          obj.freeze
        end
      end
    end

    # Event handler wrapper
    class Handler
      attr_reader :address, :block, :options, :pool_id

      def initialize(address, options = {}, &block)
        @address = address
        @block = block
        @options = options
        @local_only = options.fetch(:local_only, false)
        @pool_id = SecureRandom.uuid
      end

      def call(message)
        @block.call(message)
      rescue StandardError => e
        if defined?(Takagi.logger)
          Takagi.logger.error "Event handler error for #{@address}: #{e.message}"
        else
          warn "Event handler error for #{@address}: #{e.message}"
        end
      end

      def local_only?
        @local_only
      end
    end

    # Helper method to get configuration with fallback to ENV
    def self.config_value(config_key, env_key, default)
      # Priority: Takagi.config > ENV > default
      if defined?(Takagi.config) && Takagi.config.event_bus.respond_to?(config_key)
        Takagi.config.event_bus.public_send(config_key)
      elsif ENV[env_key]
        ENV[env_key].to_i
      else
        default
      end
    end

    # Class-level storage
    thread_default = config_value(:async_threads, 'EVENTBUS_ASYNC_THREADS', nil)
    thread_default = config_value(:ractors, 'EVENTBUS_RACTORS', 10) if thread_default.nil?
    process_count = config_value(:process_pool_size, 'EVENTBUS_PROCESS_POOL', 0)
    @executor =
      if process_count.positive?
        AsyncExecutor::ProcessExecutor.new(processes: process_count, threads: thread_default)
      else
        AsyncExecutor::ThreadExecutor.new(size: thread_default)
      end
    @handlers = Hash.new { |h, k| h[k] = [] } # address => [handlers]
    @consumers = {} # consumer_id => Handler
    @handler_store = {}
    @mutex = Mutex.new
    @current_states = EventBus::LRUCache.new(
      config_value(:state_cache_size, 'EVENTBUS_STATE_SIZE', 1000),
      config_value(:state_cache_ttl, 'EVENTBUS_STATE_TTL', 3600)
    )
    @cleanup = EventBus::ObserverCleanup.new(
      interval: config_value(:cleanup_interval, 'EVENTBUS_CLEANUP_INTERVAL', 60),
      max_age: config_value(:max_observer_age, 'EVENTBUS_MAX_OBSERVER_AGE', 600)
    )
    @cleanup.start
    @last_index = {} # For round-robin selection
    @message_store = nil # Optional message buffering (configurable)

    # Auto-enable message buffering if configured
    if defined?(Takagi.config) && Takagi.config.event_bus.message_buffering_enabled
      @message_store = MessageBuffer.new(
        max_messages: Takagi.config.event_bus.message_buffer_max_messages,
        ttl: Takagi.config.event_bus.message_buffer_ttl
      )
    end

    class << self
      # ============================================
      # PRIMARY API: Pub/Sub Pattern
      # ============================================

      # Publish message to all subscribers (pub/sub pattern)
      # @param address [String] Event address (e.g., "sensor.temperature.room1")
      # @param body [Object] Message body (must be shareable for Ractors)
      # @param headers [Hash] Optional message headers
      # @param scope [Symbol] Message scope (:local, :cluster, :global) - defaults to :local
      # @return [Message] Published message
      #
      # @example Local event (default)
      #   EventBus.publish('system.startup', { version: '1.0' })
      #
      # @example Cluster-wide event
      #   EventBus.publish('cache.invalidate', { key: 'user:123' }, scope: :cluster)
      #
      # @example Global event (cluster + external)
      #   EventBus.publish('sensor.temperature.room1', { value: 25.5 }, scope: :global)
      def publish(address, body = nil, headers: {}, scope: Scope::DEFAULT, freeze_body: true)
        message = Message.new(address, body, headers: headers, scope: scope, freeze_body: freeze_body)

        # Hook: Store message if buffering enabled
        @message_store&.store(address, message)

        # ALWAYS deliver locally (fast in-memory)
        @mutex.synchronize do
          handlers_for(address).each do |handler|
            deliver_async(handler, message)
          end

          # Wildcard handlers
          wildcard_handlers(address).each do |handler|
            deliver_async(handler, message)
          end
        end

        # Scope-aware distribution
        case message.scope
        when Scope::CLUSTER, Scope::GLOBAL
          # Cluster distribution via CoAP OBSERVE
          # ClusterBridge.publish_to_cluster(address, message)
          log_debug "Cluster distribution not yet implemented for scope: #{message.scope}"
        end

        # Global scope: external CoAP subscribers (via /.well-known/core)
        if message.scope == Scope::GLOBAL
          @current_states.set(address, message.body)
          CoAPBridge.publish_to_observers(address, message)
        end

        # Legacy distributed? check (backward compatibility)
        if distributed?(address) && message.scope == Scope::DEFAULT
          @current_states.set(address, message.body)
          CoAPBridge.publish_to_observers(address, message)
        end

        message
      end

      # Send message to single consumer (point-to-point pattern)
      # Uses round-robin if multiple consumers registered
      # @param address [String] Event address
      # @param body [Object] Message body
      # @param headers [Hash] Optional headers
      # @yield [reply_message] Optional reply handler (request-reply pattern)
      # @return [Message] Sent message
      #
      # @example
      #   EventBus.send('cache.query', { key: 'user:123' }) do |reply|
      #     puts "Cache value: #{reply.body[:value]}"
      #   end
      def send(address, body = nil, headers: {}, &reply_handler)
        reply_address = reply_handler ? generate_reply_address : nil

        # Register temporary reply handler
        if reply_handler
          consumer(reply_address, local_only: true, &reply_handler)

          # Auto-unregister after timeout
          Thread.new do
            sleep 30 # Reply timeout
            unregister(reply_address)
          end
        end

        message = Message.new(address, body, headers: headers, reply_address: reply_address)

        @mutex.synchronize do
          handler = next_handler_for(address)
          deliver_async(handler, message) if handler
        end

        message
      end

      # Synchronous send with timeout (blocking)
      # @param address [String] Event address
      # @param body [Object] Message body
      # @param headers [Hash] Optional headers
      # @param timeout [Float] Timeout in seconds (default: 1.0)
      # @return [Message] Reply message
      # @raise [Timeout::Error] If no reply received within timeout
      #
      # @example
      #   reply = EventBus.send_sync('cache.query', { key: 'user:123' }, timeout: 1.0)
      #   puts "Cache hit: #{reply.body[:hit]}"
      def send_sync(address, body = nil, headers: {}, timeout: 1.0)
        future = Future.new

        send(address, body, headers: headers) do |reply_message|
          future.set_value(reply_message)
        end

        future.value(timeout: timeout)
      rescue Timeout::Error
        raise Error, "No reply received for #{address} within #{timeout}s"
      end

      # Asynchronous send with Future (non-blocking)
      # @param address [String] Event address
      # @param body [Object] Message body
      # @param headers [Hash] Optional headers
      # @return [Future] Future that will contain reply
      #
      # @example
      #   future = EventBus.send_async('cache.query', { key: 'user:123' })
      #   # ... do other work ...
      #   reply = future.value(timeout: 1.0)
      def send_async(address, body = nil, headers: {})
        future = Future.new

        send(address, body, headers: headers) do |reply_message|
          future.set_value(reply_message)
        end

        future
      end

      # Register consumer for address (point-to-point or pub/sub)
      # @param address [String] Event address or pattern
      # @param options [Hash] Handler options
      # @option options [Boolean] :local_only Only receive local messages
      # @yield [message] Block called when message received
      # @return [String] Consumer ID (for unregistering)
      #
      # @example
      #   id = EventBus.consumer('sensor.temperature.room1') do |message|
      #     puts "Temp: #{message.body[:value]}"
      #   end
      #   EventBus.unregister(id)
      def consumer(address, options = {}, &block)
        raise ArgumentError, 'Block required' unless block

        handler = Handler.new(address, options, &block)
        consumer_id = SecureRandom.uuid

        @mutex.synchronize do
          @handlers[address] << handler
          @consumers[consumer_id] = handler
          @handler_store[handler.pool_id] = handler
        end

        @executor.register_handler(handler) if @executor.respond_to?(:register_handler)

        # Auto-create CoAP observable resource if distributed and not local_only
        if distributed?(address) && !options[:local_only] && defined?(Takagi::Base)
          CoAPBridge.register_observable_resource(address, Takagi::Base)
        end

        log_debug "Consumer registered: #{address} (#{consumer_id})"
        consumer_id
      end

      # Unregister a consumer
      # @param consumer_id [String] Consumer ID returned from consumer()
      def unregister(consumer_id)
        handler = nil
        @mutex.synchronize do
          handler = @consumers.delete(consumer_id)
          if handler
            list = @handlers[handler.address]
            list&.delete(handler)
            @handlers.delete(handler.address) if list&.empty?
            @handler_store.delete(handler.pool_id)
          end
        end

        return unless handler

        @executor.unregister_handler(handler) if @executor.respond_to?(:unregister_handler)

        log_debug "Unregistered consumer: #{consumer_id}"
      end

      # Subscribe to remote CoAP observable
      # @param address [String] Event address
      # @param node_url [String] Remote node URL (e.g., 'coap://building-a:5683')
      # @yield [message] Block called when remote notification received
      # @return [String] Subscription ID
      #
      # @example
      #   id = EventBus.subscribe_remote('sensor.temp.buildingA', 'coap://building-a:5683') do |msg|
      #     puts "Remote temp: #{msg.body[:value]}"
      #   end
      def subscribe_remote(address, node_url, &block)
        CoAPBridge.subscribe_remote(address, node_url, &block)
      end

      # ============================================
      # ALIASES: CoAP Observe + EventEmitter Style
      # ============================================

      alias observe consumer           # CoAP Observe style
      alias on consumer                # EventEmitter style
      alias notify publish             # CoAP Observe style
      alias emit publish               # EventEmitter style
      alias cancel unregister          # CoAP Observe style
      alias subscribe subscribe_remote # CoAP Observe style
      alias unsubscribe unregister     # CoAP Observe style

      # ============================================
      # MESSAGE BUFFERING CONFIGURATION
      # ============================================

      # Configure message store (for buffering/replay)
      # @param store [MessageBuffer, Object] Message store instance (nil to disable)
      # @return [MessageBuffer, Object, nil] Configured store
      #
      # @example Enable default buffering
      #   EventBus.enable_message_buffering
      #
      # @example Custom configuration
      #   EventBus.configure_message_store(
      #     MessageBuffer.new(max_messages: 200, ttl: 600)
      #   )
      #
      # @example Custom plugin store
      #   EventBus.configure_message_store(RedisMessageStore.new)
      def configure_message_store(store)
        @message_store = store
      end

      # Enable default message buffering
      # @param max_messages [Integer] Max messages per address
      # @param ttl [Integer] Time-to-live in seconds
      # @return [MessageBuffer] Configured buffer
      def enable_message_buffering(max_messages: 100, ttl: 300)
        @message_store = MessageBuffer.new(max_messages: max_messages, ttl: ttl)
      end

      # Disable message buffering
      def disable_message_buffering
        @message_store&.shutdown if @message_store.respond_to?(:shutdown)
        @message_store = nil
      end

      # Get current message store
      # @return [MessageBuffer, Object, nil] Current message store
      attr_reader :message_store

      # Replay buffered messages for an address
      # @param address [String] Event address
      # @param since [Time, nil] Return messages since this time (nil = all)
      # @return [Array<Message>] Buffered messages
      #
      # @example Replay all buffered messages
      #   EventBus.replay('sensor.temperature.room1')
      #
      # @example Replay last 60 seconds
      #   EventBus.replay('sensor.temperature.room1', since: Time.now - 60)
      def replay(address, since: nil)
        return [] unless @message_store

        @message_store.replay(address, since: since)
      end

      # Replay buffered messages to a consumer
      # Useful for late joiners or reconnecting nodes
      # @param address [String] Event address
      # @param since [Time, nil] Replay messages since this time
      # @yield [message] Block called for each buffered message
      #
      # @example Replay to new subscriber
      #   EventBus.consumer('sensor.temperature.room1') do |msg|
      #     puts "Temp: #{msg.body[:value]}"
      #   end
      #   # Catch up on last 5 minutes
      #   EventBus.replay_to('sensor.temperature.room1', since: Time.now - 300) do |msg|
      #     puts "Missed: #{msg.body[:value]}"
      #   end
      def replay_to(address, since: nil, &block)
        raise ArgumentError, 'Block required' unless block

        messages = replay(address, since: since)
        messages.each(&block)
        messages.size
      end

      # ============================================
      # UTILITY METHODS
      # ============================================

      # Check if address is distributed via CoAP
      # Uses AddressPrefix registry for extensibility
      # @param address [String] Event address
      # @return [Boolean]
      def distributed?(address)
        return false if address.to_s.start_with?('hooks.')

        AddressPrefix.distributed?(address)
      end

      # Check if address is local-only
      # Uses AddressPrefix registry for extensibility
      # @param address [String] Event address
      # @return [Boolean]
      def local_only?(address)
        AddressPrefix.local?(address)
      end

      # Get current state for address
      # @param address [String] Event address
      # @return [Object, nil] Current state or nil
      def current_state(address)
        @current_states.get(address)
      end

      # List all registered addresses
      # @return [Array<String>] Event addresses
      def addresses
        @handlers.keys
      end

      # Get handler count for address
      # @param address [String] Event address
      # @return [Integer] Number of handlers
      def handler_count(address)
        @handlers[address]&.size || 0
      end

      # Get EventBus statistics
      # @return [Hash] Statistics
      def stats
        executor_stats = if defined?(@executor) && @executor.respond_to?(:stats)
                           @executor.stats
                         else
                           {}
                         end
        base_stats = {
          consumers: @consumers.size,
          addresses: @handlers.keys.size,
          async_executor: executor_stats,
          state_cache_size: @current_states.size,
          distributed_addresses: addresses.select { |a| distributed?(a) }.size,
          local_addresses: addresses.select { |a| local_only?(a) }.size
        }

        # Add message buffer stats if enabled
        base_stats[:message_buffer] = @message_store.stats if @message_store.respond_to?(:stats)

        base_stats
      end

      # Start background cleanup
      def start_cleanup
        @cleanup.start
      end

      # Stop background cleanup
      def stop_cleanup
        @cleanup.stop
      end

      # Shutdown EventBus (cleanup resources)
      def shutdown
        stop_cleanup
        @executor.shutdown if defined?(@executor)
        @current_states.clear
        @message_store&.shutdown if @message_store.respond_to?(:shutdown)
        @mutex.synchronize do
          @handlers.clear
          @consumers.clear
          @handler_store.clear
        end
      end

      private

      # Get all handlers for exact address match
      def handlers_for(address)
        @handlers[address] || []
      end

      # Get handlers matching wildcard patterns
      # Supports: "sensor.*", "sensor.*.room1"
      def wildcard_handlers(address)
        matching = []
        parts = address.split('.')

        @handlers.each do |pattern, handlers|
          next unless pattern.include?('*')

          matching.concat(handlers) if match_pattern?(parts, pattern.split('.'))
        end

        matching
      end

      # Match address parts against pattern
      def match_pattern?(parts, pattern_parts)
        return false if pattern_parts.size != parts.size

        parts.zip(pattern_parts).all? do |part, pattern|
          pattern == '*' || pattern == part
        end
      end

      # Round-robin selection of next handler
      def next_handler_for(address)
        handlers = handlers_for(address)
        return nil if handlers.empty?

        @last_index[address] ||= -1
        @last_index[address] = (@last_index[address] + 1) % handlers.size

        handlers[@last_index[address]]
      end

      def handler_for_pool_id(pool_id)
        @handler_store[pool_id]
      end

      public :handler_for_pool_id

      # Deliver message asynchronously via Ractor pool
      def deliver_async(handler, message)
        @executor.post(handler, message)
      end

      # Generate unique reply address
      def generate_reply_address
        "reply.#{SecureRandom.uuid}"
      end

      # Log debug message
      def log_debug(message)
        return unless defined?(Takagi.logger)

        Takagi.logger.debug message
      end
    end
  end
end
