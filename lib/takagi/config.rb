# frozen_string_literal: true

require 'yaml'
require 'logger'

module Takagi
  # Stores runtime configuration loaded from YAML or manual overrides.
  class Config # rubocop:disable Metrics/ClassLength
    Observability = Struct.new(:backends, keyword_init: true)
    EventBusConfig = Struct.new(
      :ractors, :async_threads, :process_pool_size,
      :state_cache_size, :state_cache_ttl, :cleanup_interval,
      :max_observer_age, :message_buffering_enabled, :message_buffer_max_messages,
      :message_buffer_ttl, keyword_init: true
    )
    RouterConfig = Struct.new(:default_content_format, keyword_init: true)
    MiddlewareConfig = Struct.new(:enabled, :stack, keyword_init: true)
    AllocationConfig = Struct.new(:mode, :total_threads, keyword_init: true)
    PluginConfig = Struct.new(:enabled, :auto_discover, keyword_init: true)

    attr_accessor :port, :bind_address, :logger, :observability, :auto_migrate, :custom, :processes, :threads,
                  :protocols, :server_name, :event_bus, :router, :middleware, :allocation, :plugins

    def initialize
      set_server_defaults
      set_observability_defaults
      set_event_bus_defaults
      set_router_defaults
      set_middleware_defaults
      set_allocation_defaults
      set_plugin_defaults
      @custom = {}
      @server_name = nil
    end

    def [](key)
      @custom[key.to_sym]
    end

    def []=(key, value)
      @custom[key.to_sym] = value
    end

    def method_missing(name, *args, &block)
      key = name.to_s.chomp('=').to_sym
      if name.to_s.end_with?('=')
        @custom[key] = args.first
      elsif @custom.key?(key)
        @custom[key]
      else
        super(&block)
      end
    end

    def respond_to_missing?(name, include_private = false)
      key = name.to_s.chomp('=').to_sym
      @custom.key?(key) || super
    end

    def load_file(path)
      data = load_yaml(path)

      apply_basic_settings(data)
      apply_logger(data)
      apply_observability(data)
      apply_event_bus(data)
      apply_router(data)
      apply_middleware(data)
      apply_allocation(data)
      apply_plugins(data)
      apply_custom_settings(data)
    end

    private

    def apply_basic_settings(data)
      assign_setting(data, 'port') { |value| @port = value }
      assign_setting(data, 'bind_address') { |value| @bind_address = value }
      assign_processes(data)
      assign_setting(data, 'threads') { |value| @threads = value }
      assign_protocols(data['protocols'])
      assign_setting(data, 'server_name') { |value| @server_name = value }
    end

    def apply_logger(data)
      logger_config = data['logger']
      return unless logger_config.is_a?(Hash)

      output = resolve_logger_output(logger_config['output'])
      level = resolve_logger_level(logger_config['level'])
      @logger = Takagi::Logger.new(log_output: output, level: level)
    end

    def apply_observability(data)
      observability = data['observability']
      return unless observability

      backends = Array(observability['backends']).map(&:to_sym)
      @observability.backends = backends if backends.any?
    end

    def apply_event_bus(data)
      event_bus_data = data['event_bus']
      return unless event_bus_data

      assign_event_bus_core(event_bus_data)
      assign_message_buffer_settings(event_bus_data)
    end

    def apply_router(data)
      router_data = data['router']
      return unless router_data

      return unless router_data['default_content_format']

      @router.default_content_format = router_data['default_content_format']
    end

    def apply_middleware(data)
      middleware_data = data['middleware']
      return unless middleware_data

      # Enable/disable middleware globally
      @middleware.enabled = middleware_data['enabled'] if middleware_data.key?('enabled')

      # Load middleware stack from config
      return unless middleware_data['stack']

      @middleware.stack = middleware_data['stack'].map do |middleware_config|
        parse_middleware_entry(middleware_config)
      end
    end

    def apply_allocation(data)
      allocation_data = data['allocation']
      return unless allocation_data

      # Set allocation mode (:manual or :automatic)
      if allocation_data['mode']
        mode = allocation_data['mode'].to_sym
        unless [:manual, :automatic].include?(mode)
          raise ArgumentError, "Invalid allocation mode: #{mode}. Use 'manual' or 'automatic'"
        end
        @allocation.mode = mode
      end

      # Set total threads for automatic mode
      @allocation.total_threads = allocation_data['total_threads'] if allocation_data['total_threads']
    end

    def apply_plugins(data)
      plugins_data = data['plugins']
      return unless plugins_data

      if plugins_data.is_a?(Hash)
        @plugins.auto_discover = plugins_data.fetch('auto_discover', @plugins.auto_discover)
        enabled = plugins_data['enabled']
      else
        enabled = plugins_data
      end

      if enabled
        @plugins.enabled = Array(enabled).map do |entry|
          if entry.is_a?(Hash)
            { name: entry['name'] || entry[:name], options: entry['options'] || entry[:options] || {} }
          else
            { name: entry, options: {} }
          end
        end
      end
    end

    def apply_custom_settings(data)
      custom_settings = data['custom'] || {}
      custom_settings.each { |key, value| self[key] = value }
    end

    def load_yaml(path)
      content = File.read(path)
      YAML.safe_load(
        content,
        permitted_classes: [Symbol],
        aliases: true
      ) || {}
    end

    def resolve_logger_output(target)
      case target
      when nil, 'stdout'
        $stdout
      when 'stderr'
        $stderr
      else
        File.open(target.to_s, 'a')
      end
    rescue StandardError
      $stdout
    end

    def resolve_logger_level(level)
      return level if level.is_a?(Integer)
      return ::Logger::INFO unless level

      ::Logger.const_get(level.to_s.upcase)
    rescue NameError
      ::Logger::INFO
    end

    def set_server_defaults
      @port = 5683
      @bind_address = '0.0.0.0' # Bind to all interfaces by default
      @logger = ::Logger.new($stdout)
      @auto_migrate = true
      @threads = 1
      @processes = 1
      @protocols = [:udp]
    end

    def set_observability_defaults
      @observability = Observability.new(backends: [:memory])
    end

    def set_event_bus_defaults
      @event_bus = EventBusConfig.new(
        ractors: 10,
        async_threads: 10,
        process_pool_size: 0,
        state_cache_size: 1000,
        state_cache_ttl: 3600,
        cleanup_interval: 60,
        max_observer_age: 600,
        message_buffering_enabled: false,
        message_buffer_max_messages: 100,
        message_buffer_ttl: 300
      )
    end

    def set_router_defaults
      @router = RouterConfig.new(
        default_content_format: 50 # application/json
      )
    end

    def set_middleware_defaults
      @middleware = MiddlewareConfig.new(
        enabled: true,
        stack: default_middleware_stack
      )
    end

    def set_allocation_defaults
      @allocation = AllocationConfig.new(
        mode: :automatic,
        total_threads: nil
      )
    end

    def set_plugin_defaults
      @plugins = PluginConfig.new(
        enabled: [],
        auto_discover: true
      )
    end

    def assign_setting(data, key)
      value = data[key]
      return if value.nil?

      yield(value)
    end

    def assign_processes(data)
      processes_value = data['processes'] || data['process']
      return unless processes_value

      @processes = processes_value
    end

    def assign_protocols(protocols)
      return unless protocols

      @protocols = Array(protocols).map(&:to_sym)
    end

    def assign_event_bus_core(event_bus_data)
      %w[ractors async_threads process_pool_size state_cache_size state_cache_ttl cleanup_interval max_observer_age].each do |key|
        assign_event_bus_setting(event_bus_data, key)
      end
    end

    def assign_message_buffer_settings(event_bus_data)
      @event_bus.message_buffering_enabled = event_bus_data['message_buffering_enabled'] if event_bus_data.key?('message_buffering_enabled')

      assign_event_bus_setting(event_bus_data, 'message_buffer_max_messages')
      assign_event_bus_setting(event_bus_data, 'message_buffer_ttl')
    end

    def assign_event_bus_setting(event_bus_data, key)
      value = event_bus_data[key]
      return if value.nil?

      @event_bus.public_send("#{key}=", value)
    end

    # Parse middleware entry from YAML config
    # Supports both simple strings and hash with options
    #
    # @example Simple string
    #   "Logging"
    #
    # @example Hash with options
    #   { name: "Caching", options: { ttl: 300 } }
    def parse_middleware_entry(entry)
      case entry
      when String
        { name: entry, options: {} }
      when Hash
        {
          name: entry['name'] || entry[:name],
          options: entry['options'] || entry[:options] || {}
        }
      else
        raise ArgumentError, "Invalid middleware entry: #{entry.inspect}"
      end
    end

    # Default middleware stack
    # Returns an array of middleware configurations
    def default_middleware_stack
      [
        { name: 'Debugging', options: {} }
      ]
    end
  end # rubocop:enable Metrics/ClassLength
end
