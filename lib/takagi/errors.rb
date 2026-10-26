# frozen_string_literal: true

require_relative 'branding'

module Takagi
  # Enhanced error messages for better developer experience
  #
  # Provides helpful error messages with:
  # - Context about what went wrong
  # - Suggestions for how to fix it
  # - Links to documentation
  # - Similar/related options (fuzzy matching)
  module Errors
    # Base error class for Takagi-specific errors
    class TakagiError < StandardError
      attr_reader :context, :suggestions

      def initialize(message, context: {}, suggestions: [])
        @context = context
        @suggestions = suggestions
        super(build_message(message))
      end

      private

      def build_message(base_message)
        parts = ["#{Branding::LOGO} #{base_message}"]

        unless context.empty?
          parts << "\nContext:"
          context.each do |key, value|
            parts << "  #{key}: #{value.inspect}"
          end
        end

        unless suggestions.empty?
          parts << "\nDid you mean:"
          suggestions.each do |suggestion|
            parts << "  • #{suggestion}"
          end
        end

        parts.join("\n")
      end
    end

    # Raised when a reactor can't find its expected controller
    class ControllerNotFoundError < TakagiError
      def self.missing_controller(reactor_class, controller_name, available_controllers)
        similar = RegistryError.find_similar(
          controller_name.to_s,
          available_controllers.map(&:to_s)
        )

        suggestions = []
        if similar.any?
          suggestions << "Did you mean #{similar.first}?"
        end
        suggestions.concat([
          "Define #{controller_name} in your application",
          "Or use explicit config: configure { threads 4 }",
          "Or rename reactor to match an existing controller: #{available_controllers.first}"
        ])

        new(
          "#{reactor_class} expected to find #{controller_name} but it doesn't exist",
          context: {
            reactor: reactor_class.name,
            expected_controller: controller_name,
            available_controllers: available_controllers.empty? ? "(none defined)" : available_controllers.inspect,
            pattern: "Reactors auto-inherit from matching controllers by naming convention"
          },
          suggestions: suggestions
        )
      end
    end

    # Raised when registry operations fail
    class RegistryError < TakagiError
      def self.not_found(registry_name, key, available_keys)
        similar = find_similar(key.to_s, available_keys.map(&:to_s))

        new(
          "#{key.inspect} not found in #{registry_name}",
          context: {
            registry: registry_name,
            requested: key,
            available: available_keys.empty? ? "(empty registry)" : available_keys.inspect
          },
          suggestions: similar.empty? ? [] : ["Use #{similar.first.to_sym.inspect} instead?"]
        )
      end

      def self.already_registered(registry_name, key)
        new(
          "#{key.inspect} is already registered in #{registry_name}",
          context: {
            registry: registry_name,
            key: key
          },
          suggestions: [
            "Use register(#{key.inspect}, value, overwrite: true) to replace",
            "Call unregister(#{key.inspect}) first, then register again",
            "Check if key is already registered with registered?(#{key.inspect})"
          ]
        )
      end

      # Simple Levenshtein distance for fuzzy matching
      def self.find_similar(input, candidates, threshold: 3)
        candidates.select do |candidate|
          levenshtein_distance(input, candidate) <= threshold
        end.sort_by { |c| levenshtein_distance(input, c) }
      end

      def self.levenshtein_distance(s, t)
        m = s.length
        n = t.length
        return m if n == 0
        return n if m == 0

        d = Array.new(m + 1) { Array.new(n + 1) }

        (0..m).each { |i| d[i][0] = i }
        (0..n).each { |j| d[0][j] = j }

        (1..n).each do |j|
          (1..m).each do |i|
            d[i][j] = if s[i - 1] == t[j - 1]
                        d[i - 1][j - 1]
                      else
                        [d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + 1].min
                      end
          end
        end

        d[m][n]
      end
    end

    # Raised when configuration is invalid
    class ConfigurationError < TakagiError
      def self.invalid_profile(profile_name, available_profiles)
        similar = RegistryError.find_similar(profile_name.to_s, available_profiles.map(&:to_s))

        new(
          "Unknown profile: #{profile_name.inspect}",
          context: {
            requested: profile_name,
            available: available_profiles
          },
          suggestions: similar.empty? ?
            ["Use one of: #{available_profiles.map(&:inspect).join(', ')}"] :
            ["Did you mean #{similar.first.to_sym.inspect}?"]
        )
      end

      def self.missing_mount_path(controller_name)
        new(
          "#{controller_name} must specify a mount path",
          context: {
            controller: controller_name
          },
          suggestions: [
            "Add to #{controller_name}:",
            "  configure do",
            "    mount '/your-path'",
            "  end"
          ]
        )
      end

      def self.invalid_threads(value)
        new(
          "Thread count must be a positive integer, got: #{value.inspect}",
          context: {
            provided: value,
            type: value.class
          },
          suggestions: [
            "Use a positive integer: threads 4",
            "Or use a profile: profile :high_throughput"
          ]
        )
      end
    end

    # Raised when observable/observer operations fail
    class ObservableError < TakagiError
      def self.invalid_uri(uri, reason)
        new(
          "Invalid CoAP URI: #{uri.inspect}",
          context: {
            uri: uri,
            reason: reason
          },
          suggestions: [
            "Use format: coap://host:port/path",
            "Example: coap://sensor:5683/temperature",
            "For UDP: coap://...",
            "For TCP: coap+tcp://..."
          ]
        )
      end

      def self.duplicate_observable(path)
        new(
          "Observable already registered: #{path}",
          context: {
            path: path
          },
          suggestions: [
            "Each path can only have one observable definition",
            "Use different paths for different data streams",
            "Or use Bus.publish to send different events to same path"
          ]
        )
      end
    end

    # Raised when protocol/transport operations fail
    class ProtocolError < TakagiError
      def self.unsupported_protocol(protocol, supported)
        new(
          "Unsupported protocol: #{protocol.inspect}",
          context: {
            requested: protocol,
            supported: supported
          },
          suggestions: [
            "Use one of: #{supported.map(&:inspect).join(', ')}",
            "Example: run!(protocols: [:udp, :tcp])"
          ]
        )
      end

      def self.serialization_failed(content_format, error)
        new(
          "Failed to serialize response for content-format #{content_format}",
          context: {
            content_format: content_format,
            error: error.message
          },
          suggestions: [
            "Check that your response object is serializable",
            "Verify the content-format is registered: Serialization::Registry.registered?(#{content_format})",
            "Try using a different content-format in your request"
          ]
        )
      end

      def self.deserialization_failed(content_format, error, payload_preview)
        new(
          "Failed to deserialize request with content-format #{content_format}",
          context: {
            content_format: content_format,
            error: error.message,
            payload_preview: payload_preview
          },
          suggestions: [
            "Verify the payload is valid #{content_format} format",
            "Check Content-Format option matches actual payload format",
            "Try sending with explicit Content-Format header"
          ]
        )
      end
    end

    # Raised when route operations fail
    class RouteError < TakagiError
      def self.duplicate_route(method, path, existing_receiver)
        new(
          "Route already defined: #{method} #{path}",
          context: {
            method: method,
            path: path,
            existing_receiver: existing_receiver.name
          },
          suggestions: [
            "Each path can only have one handler per method",
            "Use different paths: #{method} #{path}/v2 or #{method} #{path}/alt",
            "Or use route parameters: #{method} #{path}/:version"
          ]
        )
      end

      def self.invalid_path(path, reason)
        new(
          "Invalid route path: #{path.inspect}",
          context: {
            path: path,
            reason: reason
          },
          suggestions: [
            "Paths must start with '/'",
            "Example: get '/sensors/:id' do; end",
            "Parameters use colon syntax: ':id', ':name'"
          ]
        )
      end

      def self.missing_handler(method, path)
        new(
          "No handler block provided for #{method} #{path}",
          context: {
            method: method,
            path: path
          },
          suggestions: [
            "Provide a block:",
            "  #{method.downcase} '#{path}' do",
            "    { message: 'Hello!' }",
            "  end"
          ]
        )
      end
    end

    # Raised when middleware operations fail
    class MiddlewareError < TakagiError
      def self.not_found(middleware_name, available)
        similar = RegistryError.find_similar(middleware_name.to_s, available.map(&:to_s))

        new(
          "Middleware not found: #{middleware_name.inspect}",
          context: {
            requested: middleware_name,
            available: available
          },
          suggestions: similar.any? ?
            ["Did you mean #{similar.first.to_sym.inspect}?"] :
            ["Available middleware: #{available.map(&:inspect).join(', ')}"]
        )
      end

      def self.invalid_class(middleware_class)
        new(
          "Invalid middleware class: #{middleware_class}",
          context: {
            provided: middleware_class,
            expected: "Class responding to #call(request)"
          },
          suggestions: [
            "Middleware must respond to #call(request)",
            "Example:",
            "  class MyMiddleware",
            "    def call(request)",
            "      # process request",
            "    end",
            "  end"
          ]
        )
      end
    end

    # Raised when application/server lifecycle fails
    class ServerError < TakagiError
      def self.already_running(server_info)
        new(
          "Server is already running",
          context: {
            port: server_info[:port],
            protocols: server_info[:protocols],
            pid: Process.pid
          },
          suggestions: [
            "Call shutdown! before starting again",
            "Or use different port: run!(port: #{server_info[:port] + 1})"
          ]
        )
      end

      def self.port_in_use(port, protocol)
        new(
          "Port #{port} is already in use",
          context: {
            port: port,
            protocol: protocol
          },
          suggestions: [
            "Use a different port: run!(port: #{port + 1})",
            "Stop the process using port #{port}",
            "Check with: lsof -i :#{port}"
          ]
        )
      end

      def self.no_controllers_loaded
        new(
          "No controllers loaded in application",
          context: {
            controllers_loaded: 0
          },
          suggestions: [
            "Define at least one controller:",
            "  class MyController < Takagi::Controller",
            "    get '/test' do; end",
            "  end",
            "Then load it:",
            "  class MyApp < Takagi::Application",
            "    configure { load_controllers MyController }",
            "  end"
          ]
        )
      end
    end

    # Raised when validation fails
    class ValidationError < TakagiError
      def self.invalid_thread_count(value)
        new(
          "Invalid thread count: #{value.inspect}",
          context: {
            provided: value,
            type: value.class,
            expected: "Positive integer (1..100)"
          },
          suggestions: [
            "Use a positive integer: threads 4",
            "Typical values: 1 (minimal), 4 (balanced), 8 (high load)",
            "Or use a profile: profile :high_throughput"
          ]
        )
      end

      def self.invalid_process_count(value)
        new(
          "Invalid process count: #{value.inspect}",
          context: {
            provided: value,
            type: value.class,
            expected: "Positive integer (1..32)"
          },
          suggestions: [
            "Use a positive integer: processes 4",
            "Typical values: 1 (simple), 4 (moderate), 8 (high scale)",
            "Or use a profile: profile :high_throughput"
          ]
        )
      end

      def self.missing_required_param(param_name, available_params)
        new(
          "Missing required parameter: #{param_name.inspect}",
          context: {
            required: param_name,
            received: available_params.empty? ? "(no params)" : available_params.keys
          },
          suggestions: [
            "Include #{param_name.inspect} in request payload",
            "Example: coap-client -m post coap://host/path -e '{\"#{param_name}\":\"value\"}'",
            "Or make it optional: params.fetch(:#{param_name}, default_value)"
          ]
        )
      end
    end

    # Raised when nesting/mounting fails
    class MountError < TakagiError
      def self.circular_nesting(controller_chain)
        new(
          "Circular controller nesting detected",
          context: {
            chain: controller_chain.map(&:name).join(' → ')
          },
          suggestions: [
            "Controllers cannot nest themselves directly or indirectly",
            "Restructure your controller hierarchy",
            "Chain: #{controller_chain.map(&:name).join(' → ')}"
          ]
        )
      end

      def self.invalid_mount_path(path, reason)
        new(
          "Invalid mount path: #{path.inspect}",
          context: {
            path: path,
            reason: reason
          },
          suggestions: [
            "Mount paths must start with '/'",
            "Example: mount '/api' or mount '/telemetry'",
            "Avoid trailing slashes: '/api' not '/api/'"
          ]
        )
      end

      def self.conflicting_mount(path, controller1, controller2)
        new(
          "Mount path conflict: #{path}",
          context: {
            path: path,
            controllers: [controller1.name, controller2.name]
          },
          suggestions: [
            "Two controllers cannot mount at the same path",
            "Use different paths: '#{path}/v1' and '#{path}/v2'",
            "Or nest one under the other"
          ]
        )
      end
    end
  end
end
