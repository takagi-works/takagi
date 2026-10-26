# frozen_string_literal: true

module Takagi
  # Load profiles for different IoT/CoAP use cases
  #
  # Provides predefined configurations for common scenarios to simplify
  # performance tuning without manual process/thread configuration.
  #
  # @example Using a profile
  #   class MyApp < Takagi::Application
  #     configure do
  #       profile :high_throughput
  #     end
  #   end
  #
  # @example Profile with overrides
  #   class MyApp < Takagi::Application
  #     configure do
  #       profile :high_throughput
  #       processes 16  # Override the profile's default
  #     end
  #   end
  module Profiles
    # Predefined load profiles for common IoT scenarios
    PROFILES = {
      # For devices with minimal traffic (single worker)
      # Use case: Status endpoints, health checks on constrained devices
      minimal: {
        processes: 1,
        threads: 1,
        description: 'Single-threaded, lowest resource usage for constrained devices'
      }.freeze,

      # For typical low-traffic device endpoints
      # Use case: Configuration, device status, infrequent queries
      low_traffic: {
        processes: 1,
        threads: 2,
        description: 'Configuration, status endpoints with light traffic'
      }.freeze,

      # For observable endpoints with long-lived connections
      # Use case: CoAP Observe, streaming sensor data, push notifications
      long_lived: {
        processes: 2,
        threads: 8,
        description: 'Observable resources, long-lived connections (CoAP Observe)'
      }.freeze,

      # For high-volume sensor data ingestion
      # Use case: Telemetry, sensor data from many devices, high req/sec
      high_throughput: {
        processes: 8,
        threads: 4,
        description: 'High-volume sensor telemetry and data ingestion'
      }.freeze,

      # For firmware updates, images, large file transfers
      # Use case: OTA updates, firmware downloads, large payloads
      large_payloads: {
        processes: 2,
        threads: 2,
        buffer_size: 10 * 1024 * 1024, # 10MB
        description: 'Firmware updates, file transfers, large payloads'
      }.freeze,

      # Custom configuration (must specify all parameters)
      # Use case: Fine-tuned performance for specific requirements
      custom: {
        processes: nil,
        threads: nil,
        description: 'User-defined custom configuration'
      }.freeze
    }.freeze

    class << self
      # Get a profile by name
      #
      # @param name [Symbol] Profile name
      # @return [Hash, nil] Profile configuration or nil if not found
      #
      # @example
      #   Profiles.get(:high_throughput)
      #   # => { processes: 8, threads: 4, description: '...' }
      def get(name)
        PROFILES[name]&.dup # Return copy to prevent modification
      end

      # Check if a profile exists
      #
      # @param name [Symbol] Profile name
      # @return [Boolean] true if profile exists
      #
      # @example
      #   Profiles.exists?(:high_throughput)  # => true
      #   Profiles.exists?(:unknown)          # => false
      def exists?(name)
        PROFILES.key?(name)
      end

      # Get all available profile names
      #
      # @return [Array<Symbol>] List of profile names
      #
      # @example
      #   Profiles.available
      #   # => [:minimal, :low_traffic, :long_lived, :high_throughput, :large_payloads, :custom]
      def available
        PROFILES.keys
      end

      # Get human-readable summary of all profiles
      #
      # @return [String] Formatted summary
      #
      # @example
      #   puts Profiles.summary
      def summary
        lines = ['Available Load Profiles:']
        PROFILES.each do |name, config|
          lines << ''
          lines << "  #{name}:"
          lines << "    Description: #{config[:description]}"
          lines << "    Processes: #{config[:processes] || 'custom'}"
          lines << "    Threads: #{config[:threads] || 'custom'}"
          lines << "    Buffer Size: #{config[:buffer_size]}" if config[:buffer_size]
        end
        lines.join("\n")
      end

      # Validate profile configuration
      #
      # @param name [Symbol] Profile name
      # @param config [Hash] Configuration to validate
      # @raise [ArgumentError] if profile is invalid
      #
      # @return [void]
      def validate!(name, config = nil)
        config ||= get(name)

        raise ArgumentError, "Unknown profile: #{name}" unless exists?(name)

        if name == :custom
          raise ArgumentError, 'Custom profile requires :processes' unless config[:processes]
          raise ArgumentError, 'Custom profile requires :threads' unless config[:threads]
        end

        if config[:processes] && config[:processes] < 1
          raise ArgumentError, 'Processes must be >= 1'
        end

        if config[:threads] && config[:threads] < 1
          raise ArgumentError, 'Threads must be >= 1'
        end
      end

      # Apply a profile to a configuration hash
      #
      # @param name [Symbol] Profile name
      # @param overrides [Hash] Optional overrides
      # @return [Hash] Merged configuration
      #
      # @example
      #   Profiles.apply(:high_throughput, processes: 16)
      #   # => { processes: 16, threads: 4, description: '...' }
      def apply(name, overrides = {})
        profile = get(name)
        raise ArgumentError, "Unknown profile: #{name}" unless profile

        merged = profile.merge(overrides)
        validate!(name, merged)
        merged
      end
    end
  end
end
