# frozen_string_literal: true

module Takagi
  module Observable
    # Emitter for push-based topic updates
    #
    # Allows a topic to push new state immediately when data changes, rather than
    # relying on polling intervals.
    #
    # @example Event-driven topic
    #   topic '/sensor/temp' do |emitter|
    #     TempSensor.on_change do |reading|
    #       emitter.notify({ temp: reading, unit: 'C' })
    #     end
    #   end
    #
    # @example Local bus integration
    #   topic '/alerts' do |emitter|
    #     emitter.on_event('alert.critical') do |event|
    #       { level: event.body[:severity], message: event.body[:message] }
    #     end
    #   end
    class Emitter
      attr_reader :path

      def initialize(path, topic: nil)
        @path = path
        @topic = topic
      end

      # Push a new value to observers of this path: through the bound topic's publish when
      # one exists (the topic is then the state observers are notified about), or directly
      # to the observer registry otherwise.
      #
      # @param value [Object] The value to send to observers
      # @return [void]
      #
      # @example
      #   emitter.notify({ temp: 25.5, unit: 'C' })
      def notify(value)
        return @topic.publish(value) if @topic

        Takagi::Observer::Registry.notify(@path, value)
      end

      # Subscribe to a local bus address and forward every message to this
      # observable's observers.
      #
      # The subscription is LOCAL: it registers a consumer on {Takagi.bus}, the
      # process-default {Takagi::Bus}, so nothing here reaches the network. A
      # remote CoAP Observe subscription is a different call
      # ({Takagi::Bus#subscribe_remote}) and is deliberately not used here.
      #
      # @param address [String] Local bus address to subscribe to
      # @yield [event] Optional transform block, called with the bus message
      #   ({Takagi::Bus::Message})
      # @return [String] consumer id, to be passed to {Takagi::Bus#unregister}
      #
      # @example Direct forwarding - with no block, the message's `body` is forwarded
      #   emitter.on_event('sensor.temp.changed')
      #
      # @example With transformation - the block receives the bus message
      #   emitter.on_event('sensor.temp.changed') do |event|
      #     { temp: event.body[:celsius], timestamp: event.timestamp }
      #   end
      def on_event(address, &transform)
        Takagi.bus.consumer(address) do |event|
          value = transform ? transform.call(event) : event.body
          notify(value)
        end
      end
    end
  end
end
