# frozen_string_literal: true

# `Bus` carries no sub-file requires of its own - `LRUCache` hangs off it
# from the `event_bus/*` files that `event_bus.rb` loads. A CoAP registry class body emits a hook during
# Zeitwerk eager_load (`lib/takagi/coap/registries/method.rb`), i.e. before either file has been autoloaded,
# so the bus load contract is pulled in here rather than left to the call site.
require_relative 'event_bus'

module Takagi
  # Lightweight hook dispatcher used by the plugin system to observe internal events.
  #
  # Hooks ride the local bus on ONE code path: {subscribe} registers a consumer on {Takagi.bus}
  # under the reserved `hooks.<event>` address, and {emit} publishes the payload hash to that same
  # address. A subscriber's error is captured by the bus's own delivery, so it cannot raise out of
  # {emit} nor stop the subscribers registered after it.
  module Hooks
    class << self
      # Register a handler for a given event symbol.
      #
      # @param event [Symbol] event name
      # @param handler [#call] callable that receives payload hash
      # @yield [Hash] payload if block given instead of handler
      # @return [String] consumer id, to be passed to {unsubscribe}
      def subscribe(event, handler = nil, &block)
        callback = handler || block
        raise ArgumentError, 'handler or block required' unless callback

        Takagi.bus.consumer(hook_address(event)) do |message|
          callback.call(message.body)
        end
      end

      alias on subscribe

      # Remove a previously registered handler.
      #
      # The bus unregisters by the consumer id {subscribe} returned, so the event name is
      # accepted but unused.
      #
      # @param _event [Symbol] the event the handler was subscribed to (unused)
      # @param handler [String] the consumer id returned by {subscribe}
      def unsubscribe(_event, handler)
        Takagi.bus.unregister(handler)
      end

      # Emit an event with a payload hash to all subscribers.
      #
      # @param event [Symbol]
      # @param payload [Hash]
      def emit(event, payload = {})
        Takagi.bus.publish(hook_address(event), payload, freeze_body: false)
      end

      def hook_address(event)
        "hooks.#{event}"
      end
    end
  end
end
