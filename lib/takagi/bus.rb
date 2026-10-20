# frozen_string_literal: true

require 'securerandom'

module Takagi
  # Instance-owned local event distribution.
  #
  # Subscriptions live on the instance, so two buses in one process are isolated;
  # {Bus.default} is the memoized process-wide instance serving the class-level API.
  #
  # `publish` snapshots the matching subscribers under the registry lock and then
  # delivers to that snapshot OUTSIDE it, synchronously and in registration order.
  # A subscriber registered with `async: true` is handed to the lazily built
  # executor instead, which keeps THAT subscriber's messages in publication order
  # and never runs it concurrently with itself.
  class Bus # rubocop:disable Metrics/ClassLength
    class Error < StandardError; end

    DEFAULT_LOCK = Mutex.new

    # Event message wrapper (shareable for Ractor)
    class Message
      attr_reader :address, :body, :headers, :reply_address, :timestamp

      def initialize(address, body, headers: {}, reply_address: nil, freeze_body: true)
        @address = address.freeze
        @body = freeze_body ? deep_freeze(body) : body
        @headers = deep_freeze(headers)
        @reply_address = reply_address&.freeze
        @timestamp = Time.now
      end

      # Reply to this message (request-reply pattern)
      def reply(body, headers: {})
        return unless @reply_address

        Bus.publish(@reply_address, body, headers: headers)
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
      ERROR_HOOK = :bus_subscriber_error

      attr_reader :address, :block, :options, :pool_id
      attr_accessor :consumer_id

      def initialize(address, options = {}, &block)
        @address = address
        @block = block
        @options = options
        @async = options.fetch(:async, false)
        @pool_id = SecureRandom.uuid
        @consumer_id = nil
      end

      def call(message)
        @block.call(message)
      rescue StandardError => e
        log_error(e)
        emit_error_hook(message, e)
      end

      # Deliver through the executor rather than on the publishing thread. The
      # executor keeps this subscriber's messages ordered and never runs two of
      # them at once.
      def async?
        @async
      end

      private

      def log_error(error)
        if defined?(Takagi.logger)
          Takagi.logger.error "Event handler error for #{@address}: #{error.message}"
        else
          warn "Event handler error for #{@address}: #{error.message}"
        end
      end

      # Make a swallowed subscriber error observable. The hook is emitted
      # through the regular hook path, and a failing error-hook subscriber is
      # not allowed to report itself (which would recurse forever).
      def emit_error_hook(message, error)
        return unless defined?(Takagi::Hooks)

        address = message.address
        return if address == Takagi::Hooks.hook_address(ERROR_HOOK)

        Takagi::Hooks.emit(
          ERROR_HOOK,
          address: address,
          subscriber_id: @consumer_id,
          error: error
        )
      rescue StandardError => e
        warn "bus_subscriber_error hook failed: #{e.message}"
      end
    end

    class << self
      # Helper method to get configuration with fallback to ENV
      def config_value(config_key, env_key, default)
        # Priority: Takagi.config > ENV > default
        if defined?(Takagi.config) && Takagi.config.event_bus.respond_to?(config_key)
          Takagi.config.event_bus.public_send(config_key)
        elsif ENV[env_key]
          ENV[env_key].to_i
        else
          default
        end
      end

      def default
        @default || DEFAULT_LOCK.synchronize { @default ||= new }
      end

      %i[
        publish consumer observe on notify emit cancel subscribe subscribe_remote
        unregister unsubscribe send send_sync send_async
        addresses handler_count stats shutdown executor
      ].each do |name|
        define_method(name) do |*args, **kwargs, &block|
          default.public_send(name, *args, **kwargs, &block)
        end
      end
    end

    def initialize
      @handlers = Hash.new { |h, k| h[k] = [] } # address => [handlers]
      @consumers = {} # consumer_id => Handler
      @mutex = Mutex.new
      @lazy_mutex = Mutex.new
      @executor = nil
      @last_index = {} # For round-robin selection
    end

    # ============================================
    # PRIMARY API: Pub/Sub Pattern
    # ============================================

    # Publish message to all subscribers (pub/sub pattern).
    #
    # This bus delivers locally only. `scope: :local` (or no `scope:` at all) is
    # accepted; any other scope is refused loudly, because remote and
    # cross-instance delivery does not exist here and will not pretend to.
    #
    # @param address [String] Event address (e.g., "sensor.temperature.room1")
    # @param body [Object] Message body (must be shareable for Ractors)
    # @param headers [Hash] Optional message headers
    # @param freeze_body [Boolean] Deep-freeze the body before it reaches subscribers
    # @param options [Hash] only `scope: :local` is accepted
    # @return [Message] Published message
    # @raise [ArgumentError] if a remote or cross-instance scope is requested
    #
    # @example Local event
    #   bus.publish('system.startup', { version: '1.0' })
    def publish(address, body = nil, headers: {}, freeze_body: true, **options)
      reject_remote_scope!(options[:scope]) if options.key?(:scope)

      message = Message.new(address, body, headers: headers, freeze_body: freeze_body)

      # ALWAYS deliver locally (fast in-memory), from a snapshot taken under
      # the lock but with no lock held while subscribers run.
      deliver_to_subscribers(address, message)

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
    #   bus.send('cache.query', { key: 'user:123' }) do |reply|
    #     puts "Cache value: #{reply.body[:value]}"
    #   end
    def send(address, body = nil, headers: {}, &reply_handler)
      reply_address = reply_handler ? generate_reply_address : nil

      if reply_handler
        consumer_id = consumer(reply_address) do |reply_message|
          reply_handler.call(reply_message)
        ensure
          unregister(consumer_id)
        end

        Thread.new do
          sleep 30
          unregister(consumer_id)
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
    #   reply = bus.send_sync('cache.query', { key: 'user:123' }, timeout: 1.0)
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
    #   future = bus.send_async('cache.query', { key: 'user:123' })
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
    # @option options [Boolean] :async Deliver on the executor instead of the publishing
    #   thread, still in publication order and never concurrently with itself
    # @yield [message] Block called when message received
    # @return [String] Consumer ID (for unregistering)
    #
    # @example
    #   id = bus.consumer('sensor.temperature.room1') do |message|
    #     puts "Temp: #{message.body[:value]}"
    #   end
    #   bus.unregister(id)
    def consumer(address, options = {}, &block)
      raise ArgumentError, 'Block required' unless block

      handler = Handler.new(address, options, &block)
      consumer_id = SecureRandom.uuid
      handler.consumer_id = consumer_id

      @mutex.synchronize do
        @handlers[address] << handler
        @consumers[consumer_id] = handler
      end

      @executor&.register_handler(handler)

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
        end
      end

      return unless handler

      @executor&.unregister_handler(handler)

      log_debug "Unregistered consumer: #{consumer_id}"
    end

    # Subscribe to remote CoAP observable
    # @param address [String] Event address
    # @param node_url [String] Remote node URL (e.g., 'coap://building-a:5683')
    # @yield [message] Block called when remote notification received
    # @return [String] Subscription ID
    #
    # @example
    #   id = bus.subscribe_remote('sensor.temp.buildingA', 'coap://building-a:5683') do |msg|
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
    # UTILITY METHODS
    # ============================================

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

    # Get bus statistics
    # @return [Hash] Statistics
    def stats
      executor_stats = if defined?(@executor) && @executor.respond_to?(:stats)
                         @executor.stats
                       else
                         {}
                       end
      {
        consumers: @consumers.size,
        addresses: @handlers.keys.size,
        async_executor: executor_stats
      }
    end

    attr_reader :executor

    # Shutdown bus (cleanup resources).
    #
    # Deliberately NOT terminal: the executor reference is DROPPED rather than
    # left pointing at the shut-down object, so the next asynchronous delivery
    # rebuilds an executor lazily (see #ensure_executor). Asking the dead
    # executor to restart cannot work - `ThreadExecutor#shutdown` sets a flag
    # nothing un-sets. Subscribers registered before the call are cleared and
    # the instance keeps serving later `consumer`/`publish` calls.
    def shutdown
      executor = @lazy_mutex.synchronize do
        current = @executor
        @executor = nil
        current
      end
      executor&.shutdown

      @mutex.synchronize do
        @handlers.clear
        @consumers.clear
      end
    end

    private

    # Refuse a `scope:` that asks for delivery this bus cannot perform. The bus
    # keeps no per-message scope: `:local` is the only truthful value, and
    # anything else raises, naming the work that will provide it.
    #
    # @param scope [Object] the requested scope
    # @raise [ArgumentError] for any scope other than `:local`
    def reject_remote_scope!(scope)
      return if scope.nil? || scope.to_s == 'local'

      raise ArgumentError,
            "scope: #{scope.inspect} is not supported: this local bus delivers in-process only. " \
            'Remote and cross-instance delivery is planned (the relay work), but it is not ' \
            'implemented yet; publish without a scope, or with scope: :local.'
    end

    # Deliver to a snapshot of the matching subscribers: exact-address handlers
    # first, then wildcard handlers, each group in registration order. A
    # synchronous subscriber runs on the publishing thread; one that asked for
    # `async: true` is handed to the executor in the same order. The snapshot is
    # taken under the lock; delivery is not.
    def deliver_to_subscribers(address, message)
      handlers = @mutex.synchronize { handlers_for(address) + wildcard_handlers(address) }

      handlers.each do |handler|
        if handler.async?
          deliver_async(handler, message)
        else
          handler.call(message)
        end
      end
    end

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

    # Deliver message asynchronously via the configured executor
    def deliver_async(handler, message)
      ensure_executor.post(handler, message)
    end

    # Generate unique reply address
    def generate_reply_address
      "reply.#{SecureRandom.uuid}"
    end

    def ensure_executor
      @executor || @lazy_mutex.synchronize { @executor ||= build_executor }
    end

    def build_executor
      thread_default = self.class.config_value(:async_threads, 'EVENTBUS_ASYNC_THREADS', 10)
      backlog_limit = self.class.config_value(
        :async_backlog_limit, 'EVENTBUS_ASYNC_BACKLOG', AsyncExecutor::ThreadExecutor::DEFAULT_BACKLOG_LIMIT
      )
      AsyncExecutor::ThreadExecutor.new(size: thread_default, backlog_limit: backlog_limit)
    end

    def log_debug(message)
      return unless defined?(Takagi.logger)

      Takagi.logger.debug message
    end
  end
end
