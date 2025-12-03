# frozen_string_literal: true

module Takagi
  # Lightweight hook dispatcher used by the plugin system to observe internal events.
  #
  # Hooks are intentionally simple: subscribe with a callable, emit with a hash payload.
  # Errors in subscribers are caught and logged to avoid cascading failures.
  module Hooks
    @subscribers = Hash.new { |h, k| h[k] = [] } # Fallback when EventBus unavailable
    @mutex = Mutex.new

    class << self
      # Register a handler for a given event symbol.
      #
      # @param event [Symbol] event name
      # @param handler [#call] callable that receives payload hash
      # @yield [Hash] payload if block given instead of handler
      # @return [#call] the handler reference (useful for unsubscribe)
      def subscribe(event, handler = nil, &block)
        callback = handler || block
        raise ArgumentError, 'handler or block required' unless callback

        if event_bus_ready?
          Takagi::EventBus.consumer(hook_address(event), local_only: true) do |message|
            callback.call(message.body)
          end
        else
          @mutex.synchronize { @subscribers[event] << callback }
          callback
        end
      end

      # Remove a previously registered handler.
      #
      # @param event [Symbol]
      # @param handler [#call]
      def unsubscribe(event, handler)
        if event_bus_ready?
          Takagi::EventBus.unregister(handler)
        else
          @mutex.synchronize { @subscribers[event].delete(handler) }
        end
      end

      # Emit an event with a payload hash to all subscribers.
      #
      # @param event [Symbol]
      # @param payload [Hash]
      def emit(event, payload = {})
        if event_bus_ready?
          Takagi::EventBus.publish(hook_address(event), payload, freeze_body: false, scope: Takagi::EventBus::Scope::LOCAL)
        else
          handlers = @mutex.synchronize { @subscribers[event].dup }
          return if handlers.empty?

          handlers.each do |handler|
            handler.call(payload)
          rescue StandardError => e
            begin
              Takagi.logger.warn("Hook #{event} handler error: #{e.message}")
            rescue StandardError
              # Logger may not be initialized yet; swallow errors silently.
            end
          end
        end
      end

      def hook_address(event)
        "hooks.#{event}"
      end

      def event_bus_ready?
        return false unless defined?(Takagi::EventBus)

        executor = Takagi::EventBus.instance_variable_get(:@executor) rescue nil
        return false if executor && executor.respond_to?(:running?) && !executor.running?

        true
      end
    end
  end
end
