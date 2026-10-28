# frozen_string_literal: true

module Takagi
  class Base < Router
    # Manages reactor registration and lifecycle for observable/observer patterns.
    #
    # Supports both inline reactor definitions and file-based reactor classes.
    # Provides DSL for defining observables and observers.
    module ReactorManagement
      # Defines a reactor using a DSL block (inline definition)
      #
      # The block is evaluated in the context of a new Reactor instance,
      # allowing you to define observables and observers inline.
      #
      # @param threads [Integer] Number of threads for the reactor (default: 2)
      # @param name [String] Optional name for the reactor
      # @yield Block defining reactor configuration
      #
      # @example State-carrying topic
      #   reactor threads: 4 do
      #     topic '/temperature' do |emitter|
      #       emitter.on_event('sensor.temp.changed')
      #     end
      #   end
      #
      # @example Remote observation
      #   reactor do
      #     observe 'coap://sensor:5683/temp' do |data|
      #       process_temperature(data)
      #     end
      #   end
      def reactor(threads: 2, name: nil, &block)
        reactor_name = name || "#{self.name.split('::').last.downcase}-reactor"
        reactor_instance = Takagi::Observable::Reactor.new(
          threads: threads,
          name: reactor_name
        )
        reactor_instance.instance_eval(&block)

        # Register with Observable::Registry
        Takagi::Observable::Registry.register(reactor_name.to_sym, reactor_instance)

        reactor_instance
      end

      # Registers a file-based reactor class instance
      #
      # Use this to register reactors defined in separate files (e.g., app/reactors/).
      # The reactor class should inherit from Takagi::Observable::Reactor.
      #
      # @param name [Symbol] Unique identifier for the reactor
      # @param klass_or_instance [Class, Reactor] Reactor class or instance
      #
      # @example Register reactor class
      #   class IotReactor < Takagi::Observable::Reactor
      #     def initialize
      #       super(threads: 8, name: 'iot')
      #       setup_device_observables
      #     end
      #   end
      #
      #   use_reactor :iot, IotReactor
      #
      # @example Register reactor instance
      #   use_reactor :sensors, SensorReactor.new
      def use_reactor(name, klass_or_instance)
        reactor_instance = if klass_or_instance.is_a?(Class)
                             klass_or_instance.new
                           else
                             klass_or_instance
                           end

        Takagi::Observable::Registry.register(name.to_sym, reactor_instance)
        reactor_instance
      end

      # Starts all registered reactors
      #
      # Called automatically by server lifecycle management during boot.
      # Can be called manually if needed.
      #
      # @return [void]
      def start_reactors
        Takagi::Observable::Registry.start_all
      end

      # Stops all registered reactors
      #
      # @return [void]
      def stop_reactors
        Takagi::Observable::Registry.stop_all
      end
    end
  end
end
