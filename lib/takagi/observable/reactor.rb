# frozen_string_literal: true

require_relative 'emitter'

module Takagi
  module Observable
    # Coordinator for observables (resources others watch) and observers (resources we watch)
    #
    # Supports both interval-based polling and event-driven push notifications.
    # Uses thread pools for parallel execution and resource control.
    #
    # Similar to Controllers, provides a declarative configuration API for better DX.
    #
    # @example Inline in controller
    #   class SensorController < Takagi::Controller
    #     reactor do
    #       observable '/temp' do |emitter|
    #         emitter.on_event('sensor.temp.changed')
    #       end
    #     end
    #   end
    #
    # @example Standalone reactor file (declarative)
    #   class IotReactor < Takagi::Observable::Reactor
    #     configure do
    #       threads 8
    #       name 'iot-reactor'
    #       interval 0.5
    #     end
    #
    #     observable '/sensors/temp' do |emitter|
    #       emitter.on_event('sensor.temp.changed')
    #     end
    #
    #     observe 'coap://gateway:5683/commands' do |data|
    #       handle_command(data)
    #     end
    #
    #     def handle_command(data)
    #       # Your logic here
    #     end
    #   end
    class Reactor
      attr_reader :thread_pool, :config, :observables, :observers

      class << self
        # Get or create the reactor's configuration
        #
        # @return [Hash] The reactor's configuration hash
        def config
          @config ||= {
            threads: nil,  # Will be set to 1 if no controller found
            name: nil,
            interval: 1.0,
            from_controller: nil
          }
        end

        # Configure the reactor (class-level DSL)
        #
        # @yield Block for configuration DSL
        #
        # @example
        #   configure do
        #     threads 8
        #     name 'iot-reactor'
        #     interval 0.5
        #   end
        def configure(&block)
          ConfigContext.new(self).instance_eval(&block) if block
        end

        # Inherit settings from a controller
        #
        # Associates this reactor with a controller for thread pool sharing.
        # Does NOT set threads in config to allow automatic pool sharing.
        #
        # @param controller_class [Class] Controller class to inherit from
        #
        # @example
        #   class TelemetryReactor < Takagi::Observable::Reactor
        #     inherit_from TelemetryController
        #   end
        def inherit_from(controller_class)
          config[:from_controller] = controller_class
          # Only set name, NOT threads (to allow pool sharing)
          config[:name] ||= "#{controller_class.name.split('::').last.downcase.gsub('controller', '')}-reactor"
        end

        # Define an observable at class level
        #
        # @param path [String] The resource path
        # @yield Block for observable definition
        def observable(path, &block)
          observables[path] = { type: :event_driven, block: block }
        end

        # Define a polling observable at class level
        #
        # @param path [String] The resource path
        # @param interval [Float] Polling interval
        # @yield Block for observable definition
        def observable_polling(path, interval: nil, &block)
          observables[path] = { type: :polling, interval: interval, block: block }
        end

        # Define a remote observation at class level
        #
        # @param uri [String] Remote CoAP URI
        # @yield Block for handling notifications
        def observe(uri, &block)
          observers[uri] = block
        end

        # Get class-level observables
        def observables
          @observables ||= {}
        end

        # Get class-level observers
        def observers
          @observers ||= {}
        end
      end

      def initialize(threads: nil, name: nil, interval: nil)
        # Auto-detect controller by naming convention
        auto_inherit_from_controller unless self.class.config[:from_controller]

        # Merge class config with instance overrides
        class_config = self.class.config
        controller = class_config[:from_controller]

        Takagi.logger.debug "Initializing reactor: #{self.class.name}"
        Takagi.logger.debug "  Associated controller: #{controller&.name || 'none'}"
        Takagi.logger.debug "  Explicit threads param: #{threads.inspect}"
        Takagi.logger.debug "  Class config threads: #{class_config[:threads].inspect}"

        # Determine if we should share controller's thread pool
        # Share if: controller exists AND no explicit thread configuration
        should_share_pool = controller && threads.nil? && class_config[:threads].nil?

        if should_share_pool
          Takagi.logger.debug "  Decision: Share thread pool with controller"

          # Share controller's thread pool (lazy initialization)
          @thread_pool = controller.thread_pool
          @shared_pool = true

          @config = {
            threads: @thread_pool.size,
            name: name || class_config[:name] || default_reactor_name,
            interval: interval || class_config[:interval] || 1.0
          }

          Takagi.logger.info "Reactor '#{@config[:name]}' sharing thread pool with #{controller.name} (#{@thread_pool.size} threads)"
          Takagi.logger.debug "  Shared pool object_id: #{@thread_pool.object_id}"
        else
          Takagi.logger.debug "  Decision: Create independent thread pool"

          # Create independent thread pool
          @shared_pool = false

          @config = {
            threads: threads || class_config[:threads] || 1,
            name: name || class_config[:name] || default_reactor_name,
            interval: interval || class_config[:interval] || 1.0
          }

          @thread_pool = Controller::ThreadPool.new(
            size: @config[:threads],
            name: @config[:name]
          )

          reason = if !controller
                     "no associated controller"
                   elsif threads
                     "explicit threads parameter (#{threads})"
                   elsif class_config[:threads]
                     "explicit class configuration (#{class_config[:threads]} threads)"
                   else
                     "unknown reason"
                   end

          Takagi.logger.info "Reactor '#{@config[:name]}' created independent thread pool (#{@config[:threads]} threads) - #{reason}"
          Takagi.logger.debug "  Independent pool object_id: #{@thread_pool.object_id}"
        end

        @observables = {}
        @observers = {}
        @running = false
        @watcher = Observer::Watcher.new(interval: @config[:interval])

        Takagi.logger.debug "Reactor initialization complete: #{@config[:name]}"

        # Register class-level observables and observers
        setup_class_definitions
      end

      private

      # Auto-detect and inherit from controller based on naming convention
      #
      # IotReactor → IotController
      # SensorReactor → SensorController
      def auto_inherit_from_controller
        controller_name = self.class.name&.gsub(/Reactor$/, 'Controller')
        return unless controller_name

        begin
          controller_class = Object.const_get(controller_name)
          self.class.inherit_from(controller_class) if controller_class.is_a?(Class)
        rescue NameError
          # Controller doesn't exist, use defaults
        end
      end

      # Generate default reactor name based on class name
      def default_reactor_name
        class_name = self.class.name&.split('::')&.last || 'reactor'
        class_name.gsub(/Reactor$/, '').downcase + '-reactor'
      end

      def setup_class_definitions
        # Register class-level observables
        self.class.observables.each do |path, definition|
          if definition[:type] == :event_driven
            observable(path, &definition[:block])
          else
            observable_polling(path, interval: definition[:interval], &definition[:block])
          end
        end

        # Register class-level observers
        self.class.observers.each do |uri, block|
          observe(uri, &block)
        end
      end

      # Configuration context for DSL
      class ConfigContext
        def initialize(reactor_class)
          @reactor_class = reactor_class
        end

        def threads(count)
          @reactor_class.config[:threads] = count
        end

        def name(reactor_name)
          @reactor_class.config[:name] = reactor_name
        end

        def interval(seconds)
          @reactor_class.config[:interval] = seconds
        end

        def inherit_from(controller_class)
          @reactor_class.inherit_from(controller_class)
        end
      end

      public

      # Define an event-driven observable (push-based)
      #
      # The block receives an emitter that can push updates immediately
      # when data changes, without relying on polling.
      #
      # @param path [String] The resource path
      # @yield [emitter] Block that sets up event listeners
      # @return [void]
      #
      # @example EventBus-driven
      #   observable '/alerts' do |emitter|
      #     emitter.on_event('alert.critical')
      #   end
      #
      # @example Custom events
      #   observable '/temp' do |emitter|
      #     TempSensor.on_change { |val| emitter.notify(val) }
      #   end
      def observable(path, &block)
        emitter = Emitter.new(path)
        @observables[path] = {
          type: :event_driven,
          emitter: emitter,
          block: block
        }

        # Register with router so it can be requested
        Takagi::Base.router.observable(path, &block)

        # Initialize the observable in thread pool
        schedule_in_pool do
          block.call(emitter)
        end

        Takagi.logger.debug "Event-driven observable registered: #{path}"
      end

      # Define a polling observable (interval-based)
      #
      # The block is called periodically at the specified interval.
      # Use this for checking remote resources or when event-driven isn't possible.
      #
      # @param path [String] The resource path
      # @param interval [Float] Seconds between polls (default: reactor's interval)
      # @yield Block that returns the current value
      # @return [void]
      #
      # @example Polling remote resource
      #   observable_polling '/external/status', interval: 5.0 do
      #     check_external_api
      #   end
      def observable_polling(path, interval: @config[:interval], &block)
        @observables[path] = {
          type: :polling,
          interval: interval,
          block: block,
          last_run: nil
        }

        # Register with router
        Takagi::Base.router.observable(path, &block)

        # Start polling loop in thread pool
        schedule_in_pool do
          poll_observable(path, interval, &block)
        end

        Takagi.logger.debug "Polling observable registered: #{path} (interval: #{interval}s)"
      end

      # Manually trigger a notification for an observable
      #
      # Useful for triggering updates from request handlers or other code.
      #
      # @param path [String] The observable path
      # @param value [Object] The value to send
      # @return [void]
      #
      # @example In a controller action
      #   post '/data' do
      #     process_data(request)
      #     reactor.notify('/summary', calculate_summary)
      #   end
      def notify(path, value)
        schedule_in_pool do
          Observer::Registry.notify(path, value)
        end
      end

      # Observe a remote resource
      #
      # Subscribe to changes on a remote CoAP server.
      #
      # @param uri [String] CoAP URI to observe
      # @yield [payload, inbound] Block called when notification received
      # @return [void]
      #
      # @example
      #   observe 'coap://sensor:5683/temp' do |data|
      #     process_temperature(data)
      #   end
      def observe(uri, &block)
        Takagi.logger.info("Observing remote resource: #{uri}")
        @observers[uri] = { uri: uri, handler: block }

        parsed = URI.parse(uri)
        path = parsed.path

        # Register local subscription
        Observer::Registry.subscribe(
          path,
          address: parsed.host,
          port: parsed.port || 5683,
          token: SecureRandom.hex(2),
          handler: block
        )

        # Start observation in thread pool
        schedule_in_pool do
          client = Observer::Client.new(uri)
          client.on_notify(&block)
          client.subscribe
        end
      end

      # Trigger an observe notification manually
      #
      # @param uri [String] The URI to trigger
      # @param value [Object] The value
      # @return [void]
      def trigger_observe(uri, value)
        path = URI.parse(uri).path
        Takagi.logger.debug "Trigger observe for path: #{path} with value: #{value}"
        Observer::Registry.notify(path, value)
      end

      # Start the reactor
      #
      # Starts the thread pool and any background watchers.
      #
      # @return [void]
      def start
        return if @running

        @running = true
        @watcher.start if has_polling_observables?

        Takagi.logger.info "Reactor '#{@config[:name]}' started with #{@config[:threads]} threads"
        Takagi.logger.debug "  Event-driven observables: #{event_driven_count}"
        Takagi.logger.debug "  Polling observables: #{polling_count}"
        Takagi.logger.debug "  Remote observers: #{@observers.size}"
      end

      # Stop the reactor
      #
      # Gracefully shuts down the thread pool and watchers.
      # Only shuts down thread pool if we own it (not shared).
      #
      # @return [void]
      def stop
        return unless @running

        Takagi.logger.debug "Stopping reactor: #{@config[:name]}"
        Takagi.logger.debug "  Shared pool: #{@shared_pool}"

        @running = false
        @watcher.stop if @watcher

        # Only shutdown thread pool if we own it (not shared)
        if @shared_pool
          Takagi.logger.debug "  Skipping thread pool shutdown (shared with controller)"
          Takagi.logger.info "Reactor '#{@config[:name]}' stopped (thread pool remains active for controller)"
        else
          Takagi.logger.debug "  Shutting down independent thread pool"
          @thread_pool.shutdown
          Takagi.logger.info "Reactor '#{@config[:name]}' stopped (thread pool shutdown)"
        end
      end

      # Check if reactor is running
      #
      # @return [Boolean]
      def running?
        @running
      end

      # Check if reactor is sharing a thread pool with its controller
      #
      # @return [Boolean]
      def shared_pool?
        @shared_pool || false
      end

      private

      # Schedules observer work in the reactor's pool only when that pool lives in THIS process,
      # and otherwise runs it in the calling thread.
      #
      # A reactor that shares a controller's pool holds the pool OBJECT, and a forked child
      # inherits that object with its threads already gone (threads do not survive `fork`), so a
      # plain `ThreadPool#schedule` there pushes work into a queue whose drainer died - the
      # notification vanishes with no trace and the side effect never happens (row 26 of
      # .omo/plans/tcp-multi-worker.md). The request path refuses to do that - a forked UDP worker
      # serves synchronously when `Controller#workers_running?` is false - so a child does the same
      # here and the side effect still happens exactly once.
      def schedule_in_pool(&block)
        return @thread_pool.schedule(&block) if @thread_pool.running_in_this_process?

        Takagi.logger.debug(
          "Reactor '#{@config[:name]}' runs observer work synchronously: its pool belongs to " \
          'another process (a pool thread does not survive a fork)'
        )
        block.call
      end

      def poll_observable(path, interval, &block)
        loop do
          break unless @running

          begin
            value = block.call
            Observer::Registry.notify(path, value)
          rescue StandardError => e
            Takagi.logger.error "Polling observable #{path} error: #{e.message}"
          end

          sleep interval
        end
      end

      def has_polling_observables?
        @observables.any? { |_path, obs| obs[:type] == :polling }
      end

      def event_driven_count
        @observables.count { |_path, obs| obs[:type] == :event_driven }
      end

      def polling_count
        @observables.count { |_path, obs| obs[:type] == :polling }
      end
    end
  end
end
