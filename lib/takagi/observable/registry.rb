# frozen_string_literal: true

module Takagi
  module Observable
    # Registry for reactor instances
    #
    # Manages reactor lifecycle and provides consistent API for reactor management.
    # Uses Registry::Base for thread-safe storage and standard operations.
    #
    # @example Register reactors
    #   Observable::Registry.register(:iot, IotReactor.new)
    #   Observable::Registry.register(:sensors, SensorReactor.new)
    #
    # @example Start all reactors
    #   Observable::Registry.start_all
    #
    # @example Access specific reactor
    #   reactor = Observable::Registry.get(:iot)
    #   reactor.notify('/temp', 25.5)
    class Registry
      extend Takagi::Registry::Base

      class << self
        # Register a reactor instance
        #
        # @param name [Symbol] Unique identifier for the reactor
        # @param reactor [Reactor] Reactor instance
        # @param metadata [Hash] Optional metadata
        # @return [void]
        #
        # @example
        #   Registry.register(:sensors, SensorReactor.new, description: 'IoT sensors')
        def register(name, reactor, **metadata)
          super(name.to_sym, reactor, **metadata)
        end

        # Get all registered reactors
        #
        # @return [Array<Reactor>] List of reactor instances
        def reactors
          @mutex.synchronize { registry.values }
        end

        # Start all registered reactors
        #
        # @return [void]
        def start_all
          reactor_list = reactors
          reactor_list.each do |reactor|
            reactor.start unless reactor.running?
          end
          Takagi.logger.info "Started #{reactor_list.size} reactor(s)"
        end

        # Stop all registered reactors
        #
        # Safe to call from signal traps (doesn't use mutex directly)
        #
        # @return [void]
        def stop_all
          # Get reactors list without holding mutex (avoid trap context issues)
          reactor_list = begin
                           @mutex.synchronize { registry.values.dup }
                         rescue ThreadError
                           # If called from trap context, access without lock
                           registry.values.dup
                         end

          reactor_list.each do |reactor|
            reactor.stop if reactor.running?
          end
          Takagi.logger.info "Stopped #{reactor_list.size} reactor(s)"
        end

        # Allocate thread resources across reactors
        #
        # Distributes available threads among registered reactors based on weights.
        #
        # @param total_threads [Integer] Total threads to allocate
        # @return [Hash] Map of reactor name => allocated threads
        #
        # @example
        #   Registry.allocate_resources(total_threads: 20)
        #   # => { iot: 10, sensors: 6, alerts: 4 }
        def allocate_resources(total_threads: 10)
          reactor_list = reactors
          return {} if reactor_list.empty?

          threads_per_reactor = total_threads / reactor_list.size
          threads_per_reactor = [threads_per_reactor, 1].max

          allocations = {}
          reactor_list.each do |reactor|
            name = keys.find { |k| self[k] == reactor }
            reactor.thread_pool.resize(threads_per_reactor) if reactor.thread_pool.respond_to?(:resize)
            allocations[name] = threads_per_reactor
          end

          Takagi.logger.debug "Allocated #{threads_per_reactor} threads per reactor"
          allocations
        end

        # Get statistics for all reactors
        #
        # @return [Hash] Map of reactor name => stats
        def stats
          result = {}
          each do |name, reactor|
            result[name] = {
              running: reactor.running?,
              topics: reactor.topics.size,
              observers: reactor.observers.size,
              threads: reactor.config[:threads],
              thread_pool_stats: reactor.thread_pool.current_stats
            }
          end
          result
        end
      end
    end
  end
end
