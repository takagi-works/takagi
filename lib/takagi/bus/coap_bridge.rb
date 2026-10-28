# frozen_string_literal: true

require 'set'

module Takagi
  class Bus
    # CoAP Observe integration - maps events to CoAP resources
    # Thread-safe with Mutex for resource registration
    #
    # Maps Bus addresses to CoAP observable resources:
    # - "sensor.temperature.room1" -> "/events/sensor/temperature/room1"
    #
    # @example
    #   CoAPBridge.register_observable_resource('sensor.temp.room1', app)
    #   CoAPBridge.publish_to_observers('sensor.temp.room1', message)
    class CoAPBridge
      @registered_resources = Set.new
      @apps = {}
      @mutex = Mutex.new

      class << self
        # Convert event address to CoAP path
        # @param address [String] Event address (e.g., "sensor.temperature.room1")
        # @return [String] CoAP path (e.g., "/events/sensor/temperature/room1")
        #
        # @example
        #   CoAPBridge.address_to_path('sensor.temperature.room1')
        #   # => "/events/sensor/temperature/room1"
        def address_to_path(address)
          "/events/#{address.gsub('.', '/')}"
        end

        # Convert CoAP path to event address
        # @param path [String] CoAP path (e.g., "/events/sensor/temperature/room1")
        # @return [String] Event address (e.g., "sensor.temperature.room1")
        #
        # @example
        #   CoAPBridge.path_to_address('/events/sensor/temperature/room1')
        #   # => "sensor.temperature.room1"
        def path_to_address(path)
          path.sub(%r{^/events/}, '').gsub('/', '.')
        end

        # Register an observable CoAP resource (thread-safe)
        # Creates a CoAP topic endpoint for the address. Its declaration block runs once,
        # producing a constant descriptor; the first `publish_to_observers` for the address
        # makes the topic serve the latest event state - the state layer this bridge
        # supplies. The local bus itself keeps no state and never reaches into the bridge
        # on its own.
        #
        # @param address [String] Event address
        # @param app [Class] Application class (must respond to #topic)
        # @return [Boolean] True if registered, false if already exists
        #
        # @example
        #   CoAPBridge.register_observable_resource('sensor.temp.room1', MyApp)
        def register_observable_resource(address, app)
          # Thread-safe check-and-register
          @mutex.synchronize do
            # Already registered?
            return false if @registered_resources.include?(address)

            # Mark as registered before creating resource
            @registered_resources << address
            @apps[address] = app

            path = address_to_path(address)

            begin
              # Create the CoAP topic endpoint; a future state layer supplies values.
              app.topic path do
                { address: address, status: 'observable', timestamp: Time.now.to_i }
              end

              Takagi.logger.info "Observable resource created: #{path} (#{address})"
              true
            rescue StandardError => e
              # If registration fails, remove from set
              @registered_resources.delete(address)
              @apps.delete(address)
              Takagi.logger.error "Failed to register observable resource #{address}: #{e.message}"
              false
            end
          end
        end

        # Publish event to all CoAP observers
        # Notifies all observers subscribed via CoAP Observe
        #
        # @param address [String] Event address
        # @param message [Bus::Message] Event message
        #
        # @example
        #   message = Bus::Message.new('sensor.temp.room1', { value: 25.5 })
        #   CoAPBridge.publish_to_observers('sensor.temp.room1', message)
        def publish_to_observers(address, message)
          path = address_to_path(address)

          # Build notification payload
          state = {
            address: address,
            body: message.body,
            headers: message.headers,
            timestamp: message.timestamp.to_i
          }

          # Publish through the registered topic when one exists: it becomes the served
          # representation and its observers are notified. Without a topic the bridge
          # falls back to a direct registry notification.
          topic = topic_for(path)
          if topic
            topic.publish(state)
          elsif defined?(Takagi::ObserveRegistry)
            Takagi::ObserveRegistry.notify(path, state)
          else
            Takagi.logger.warn 'ObserveRegistry not available, cannot publish to observers'
          end
        rescue StandardError => e
          # The bus keeps no retention/replay layer, so a failed notification is
          # logged and dropped rather than handed to bus state.
          Takagi.logger.error "Error publishing to observers for #{address}: #{e.message}"
        end

        # Subscribe to remote event via CoAP Observe
        # @param address [String] Event address
        # @param node_url [String] Remote node URL (e.g., 'coap://building-a:5683')
        # @raise [NotImplementedError] until remote CoAP Observe subscriptions are implemented
        #
        # @example
        #   CoAPBridge.subscribe_remote('sensor.temp.buildingA', 'coap://building-a:5683') do |msg|
        #     puts "Remote temp: #{msg.body[:value]}"
        #   end
        def subscribe_remote(address, node_url)
          raise NotImplementedError,
                "CoAPBridge.subscribe_remote(#{address.inspect}, #{node_url.inspect}) is not implemented; " \
                'remote CoAP Observe subscriptions to Bus addresses are planned but unavailable'
        end

        # Check if resource is registered
        # @param address [String] Event address
        # @return [Boolean]
        def registered?(address)
          @mutex.synchronize { @registered_resources.include?(address) }
        end

        # The topic this bridge registered for an address, through the app that owns it.
        #
        # @param address [String] Event address
        # @return [Takagi::Topic, nil]
        def topic_for(path)
          app = @apps[path_to_address(path)]
          return nil unless app

          router = app.respond_to?(:router) ? app.router : nil
          return nil unless router.respond_to?(:topic_for)

          router.topic_for(path)
        end

        # Get all registered resource addresses
        # @return [Array<String>]
        def registered_addresses
          @mutex.synchronize { @registered_resources.to_a }
        end

        # Get count of registered resources
        # @return [Integer]
        def registered_count
          @mutex.synchronize { @registered_resources.size }
        end

        # Unregister a resource (for testing)
        # @param address [String] Event address
        # @return [Boolean] True if was registered, false otherwise
        def unregister(address)
          @mutex.synchronize do
            # Set#delete? returns the set if element was present, nil if not
            # Convert to boolean: true if was present, false if not
            removed = !!@registered_resources.delete?(address)
            @apps.delete(address)
            removed
          end
        end

        # Clear all registrations (for testing)
        def clear
          @mutex.synchronize do
            @registered_resources.clear
            @apps.clear
          end
        end
      end
    end
  end
end
