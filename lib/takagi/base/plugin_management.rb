# frozen_string_literal: true

require_relative '../plugin'
require_relative '../hooks'

module Takagi
  class Base < Router
    # Provides a simple DSL for declaring and enabling plugins on boot.
    module PluginManagement
      def plugin(plugin_ref, **options)
        plugins_config << { ref: plugin_ref, options: options }
      end

      def enable_plugins!(app: self)
        load_config_plugins
        Takagi::Plugin.auto_discover! if Takagi.config.plugins.auto_discover

        merged = merged_plugins
        merged.each do |entry|
          mod = resolve_plugin(entry[:ref])
          info = Takagi::Plugin.register(mod)
          Takagi::Plugin.enable(info.name, app: app, options: entry[:options])
        end
      end

      private

      def plugins_config
        @plugins_config ||= []
      end

      def load_config_plugins
        config_entries = Array(Takagi.config.plugins.enabled)
        config_entries.each do |entry|
          if entry.is_a?(Hash)
            plugins_config << { ref: entry[:name] || entry['name'], options: entry[:options] || entry['options'] || {} }
          else
            plugins_config << { ref: entry, options: {} }
          end
        end
      end

      def merged_plugins
        seen = {}
        plugins_config.reverse_each do |entry|
          key = entry[:ref].to_s
          seen[key] ||= entry
        end
        seen.values.reverse
      end

      def resolve_plugin(ref)
        return ref if ref.is_a?(Module)

        # Try Takagi::Plugins::<Name>
        if ref.is_a?(Symbol) || ref.is_a?(String)
          const_name = ref.to_s.split('_').map(&:capitalize).join
          begin
            return Takagi::Plugins.const_get(const_name)
          rescue NameError
            # fall through
          end
          # Try fully qualified
          return Object.const_get(ref.to_s)
        end

        raise ArgumentError, "Unknown plugin reference: #{ref.inspect}"
      end
    end
  end
end
