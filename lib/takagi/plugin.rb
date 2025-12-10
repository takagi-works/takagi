# frozen_string_literal: true

require 'rubygems'
require_relative 'hooks'

module Takagi
  # Plugin manager: registers plugins, validates metadata/config, resolves dependencies, and emits lifecycle events.
  class Plugin
    PluginInfo = Struct.new(:name, :module, :enabled, :metadata, :dependencies, :requires, keyword_init: true)

    @registry = {}
    @mutex = Mutex.new

    class << self
      attr_reader :registry

      # Register a plugin module that responds to .apply(app, opts = {}) and .metadata
      def register(plugin_module)
        metadata = safe_metadata(plugin_module)
        raw_name = metadata[:name] || plugin_module.name&.split('::')&.last || "plugin_#{plugin_module.object_id}"
        name = raw_name.to_sym
        deps = Array(metadata[:dependencies]).map { |dep| normalize_dependency(dep) }
        requires = metadata[:requires]

        info = PluginInfo.new(
          name: name.to_sym,
          module: plugin_module,
          enabled: false,
          metadata: metadata,
          dependencies: deps,
          requires: requires
        )

        @mutex.synchronize { @registry[name.to_sym] = info }
        Takagi::Hooks.emit(:plugin_registered, name: name, metadata: metadata)
        info
      end

      # Enable a plugin by name. Optionally pass options to apply.
      def enable(name, app:, options: {})
        info = @mutex.synchronize { @registry[name.to_sym] }
        raise ArgumentError, "Plugin #{name} not registered" unless info
        return info if info.enabled

        validate_version!(info)
        resolve_dependencies!(info, app: app)

        validated_options = validate_config!(info.module, options, plugin_name: info.name)

        app_for_plugin = wrap_app_with_prefix(app, info)

        Takagi::Hooks.emit(:plugin_enabling, name: name, metadata: info.metadata, options: validated_options)
        plugin = info.module
        plugin.before_apply(app_for_plugin, validated_options) if plugin.respond_to?(:before_apply)
        plugin.apply(app_for_plugin, validated_options)
        plugin.after_apply(app_for_plugin, validated_options) if plugin.respond_to?(:after_apply)

        info.enabled = true
        Takagi::Hooks.emit(:plugin_enabled, name: name, metadata: info.metadata)
        info
      rescue StandardError => e
        Takagi::Hooks.emit(:plugin_error, name: name, metadata: info&.metadata, error: e)
        raise
      end

      def disable(name, app:)
        info = @mutex.synchronize { @registry[name.to_sym] }
        return unless info&.enabled

        Takagi::Hooks.emit(:plugin_disabling, name: name, metadata: info.metadata)
        plugin = info.module
        plugin.before_unload(app) if plugin.respond_to?(:before_unload)
        plugin.shutdown(app) if plugin.respond_to?(:shutdown)
        info.enabled = false
        Takagi::Hooks.emit(:plugin_disabled, name: name, metadata: info.metadata)
        info
      rescue StandardError => e
        Takagi::Hooks.emit(:plugin_error, name: name, metadata: info&.metadata, error: e)
        raise
      end

      def unregister(name)
        @mutex.synchronize { @registry.delete(name.to_sym) }
      end

      def list
        @mutex.synchronize { @registry.values.map { |info| { name: info.name, enabled: info.enabled, metadata: info.metadata } } }
      end

      # Auto-discover plugins under Takagi::Plugins namespace and takagi-plugin-* gems
      def auto_discover!
        discover_namespace_plugins
        discover_gem_plugins
      end

      private

      def wrap_app_with_prefix(app, info)
        prefix = info.metadata[:route_prefix]
        return app unless prefix

        RoutePrefixProxy.new(app, prefix)
      end

      def safe_metadata(mod)
        mod.respond_to?(:metadata) ? (mod.metadata || {}) : {}
      rescue StandardError
        {}
      end

      def validate_version!(info)
        return unless info.requires && defined?(Takagi::VERSION)

        # naive comparison; assumes semver strings
        required = info.requires
        current = Gem::Version.new(Takagi::VERSION) rescue nil
        required_version = Gem::Version.new(required) rescue nil
        return unless current && required_version

        if current < required_version
          raise ArgumentError, "Plugin #{info.name} requires Takagi #{required} but current is #{Takagi::VERSION}"
        end
      end

      def resolve_dependencies!(info, app:)
        return if info.dependencies.nil? || info.dependencies.empty?

        info.dependencies.each do |dep_name|
          dep_key = dep_name[:name]
          dep = @mutex.synchronize { @registry[dep_key] }
          raise ArgumentError, "Plugin #{info.name} missing dependency #{dep_key}" unless dep

          if dep_name[:version] && dep.metadata[:version]
            requirement = Gem::Requirement.new(dep_name[:version])
            dep_version = Gem::Version.new(dep.metadata[:version])
            unless requirement.satisfied_by?(dep_version)
              raise ArgumentError, "Plugin #{info.name} requires #{dep_key} #{dep_name[:version]}, found #{dep.metadata[:version]}"
            end
          end

          enable(dep.name, app: app) unless dep.enabled
        end
      end

      def validate_config!(plugin_mod, options, plugin_name:)
        return options unless plugin_mod.respond_to?(:config_schema)

        schema = plugin_mod.config_schema || {}
        opts = symbolize_keys(options || {})
        validated = {}

        schema.each do |key, rules|
          value = opts.key?(key) ? opts[key] : rules[:default]

          if value.nil? && rules[:required]
            raise ArgumentError, "Missing required config for #{key} in plugin #{plugin_name}"
          end

          unless value.nil?
            expected = rules[:type]
            validate_type!(key, value, expected, plugin_name: plugin_name) if expected
            validate_enum!(key, value, rules[:enum], plugin_name: plugin_name) if rules[:enum]
            validate_range!(key, value, rules[:range], plugin_name: plugin_name) if rules[:range]
            if rules[:validate].respond_to?(:call)
              raise ArgumentError, "Invalid value for #{key} in plugin #{plugin_name}" unless rules[:validate].call(value)
            end
          end

          validated[key] = value
        end

        # Pass through extra keys
        opts.each do |k, v|
          validated[k] = v unless validated.key?(k)
        end

        validated
      end

      def validate_type!(key, value, expected, plugin_name:)
        ok = case expected
             when :string then value.is_a?(String)
             when :integer then value.is_a?(Integer)
             when :boolean then value == true || value == false
             when :hash then value.is_a?(Hash)
             when :array then value.is_a?(Array)
             else true
             end
        raise ArgumentError, "Invalid type for #{key} in plugin #{plugin_name}: expected #{expected}, got #{value.class}" unless ok
      end

      def validate_enum!(key, value, enum, plugin_name:)
        return unless enum
        raise ArgumentError, "Invalid value for #{key} in plugin #{plugin_name}: #{value}, expected one of #{enum.inspect}" unless enum.include?(value)
      end

      def validate_range!(key, value, range, plugin_name:)
        return unless range && value.is_a?(Numeric)
        raise ArgumentError, "Value for #{key} in plugin #{plugin_name} out of range #{range}" unless range.cover?(value)
      end

      def symbolize_keys(hash)
        hash.each_with_object({}) { |(k, v), acc| acc[k.to_sym] = v }
      end

      def discover_namespace_plugins
        return unless defined?(Takagi::Plugins)

        Takagi::Plugins.constants.each do |const|
          mod = Takagi::Plugins.const_get(const)
          next unless mod.is_a?(Module)
          next unless mod.respond_to?(:apply)

          register(mod) unless @registry.key?(infer_name(mod))
        end
      rescue StandardError
        nil
      end

      def discover_gem_plugins
        specs = Gem::Specification.each.select { |s| s.name.start_with?('takagi-plugin-') }
        specs.each do |spec|
          begin
            require spec.name
          rescue LoadError => e
            Takagi::Hooks.emit(:plugin_error, name: spec.name, metadata: nil, error: e)
            next
          end

          mod = infer_module_from_gem(spec)
          register(mod) if mod && mod.respond_to?(:apply) && !@registry.key?(infer_name(mod))
        end
      end

      def infer_name(mod)
        if mod.respond_to?(:metadata) && mod.metadata && mod.metadata[:name]
          mod.metadata[:name].to_sym
        elsif mod.name
          mod.name.split('::').last.downcase.to_sym
        end
      end

      def infer_module_from_gem(spec)
        return unless defined?(Takagi::Plugins)

        suffix = spec.name.sub(/^takagi-plugin-/, '')
        const_name = suffix.split(/[-_]/).map(&:capitalize).join
        Takagi::Plugins.const_get(const_name)
      rescue NameError
        nil
      end

      def normalize_dependency(dep)
        return { name: dep.to_sym } unless dep.is_a?(Hash)

        {
          name: (dep[:name] || dep['name']).to_sym,
          version: dep[:version] || dep['version']
        }
      end
    end
  end
end

# Wraps the app to prefix routes registered by a plugin.
class Takagi::Plugin::RoutePrefixProxy
  ROUTE_METHODS = %i[get post put delete fetch observable observe].freeze

  def initialize(app, prefix)
    @app = app
    @prefix = normalize_prefix(prefix)
  end

  ROUTE_METHODS.each do |method_name|
    define_method(method_name) do |path, *args, **kwargs, &block|
      prefixed_path = prefix_path(path)
      @app.public_send(method_name, prefixed_path, *args, **kwargs, &block)
    end
  end

  def method_missing(name, *args, **kwargs, &block)
    if @app.respond_to?(name)
      @app.public_send(name, *args, **kwargs, &block)
    else
      super
    end
  end

  def respond_to_missing?(name, include_private = false)
    @app.respond_to?(name, include_private) || super
  end

  private

  def prefix_path(path)
    return path unless path.is_a?(String)

    "#{@prefix}#{path}".gsub(%r{//+}, '/')
  end

  def normalize_prefix(prefix)
    str = prefix.to_s
    return '' if str.empty?

    str.start_with?('/') ? str : "/#{str}"
  end
end
