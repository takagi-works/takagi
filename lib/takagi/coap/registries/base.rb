# frozen_string_literal: true

module Takagi
  module CoAP
    module Registries
      # Base class for extensible constant registries.
      #
      # Provides a pattern for registering CoAP protocol constants with:
      # - Numeric value
      # - Human-readable name
      # - Symbol accessor (optional)
      # - Thread-safe storage
      #
      # This allows plugins to extend the protocol without modifying core code.
      #
      # @example Creating a custom registry
      #   class MyRegistry < Registries::Base
      #     register(1, 'First Value', :first)
      #     register(2, 'Second Value', :second)
      #   end
      #
      #   MyRegistry::FIRST   # => 1
      #   MyRegistry.name_for(1)  # => "First Value"
      #   MyRegistry.all      # => {1 => "First Value", 2 => "Second Value"}
      require 'takagi/hooks'

      class Base
        def self.inherited(subclass)
          super
          subclass.instance_variable_set(:@mutex, Mutex.new)
        end

        class << self
          # Register a new constant in the registry
          #
          # @param value [Integer] Numeric value of the constant
          # @param name [String] Human-readable name
          # @param symbol [Symbol, nil] Optional symbol for constant access
          # @param rfc [String, nil] Optional RFC reference
          #
          # @example
          #   register(69, '2.05 Content', :content, rfc: 'RFC 7252 §5.9.1.4')
          def register(value, name, symbol = nil, rfc: nil)
            @mutex.synchronize do
              registry[value] = {
                name: name,
                symbol: symbol,
                rfc: rfc
              }

              # Create constant if symbol provided
              if symbol
                const_name = symbol.to_s.upcase
                const_set(const_name, value) unless const_defined?(const_name, false)
              end

              # Store reverse lookup
              reverse_registry[name] = value if name
              reverse_registry[symbol] = value if symbol
            end

            Takagi::Hooks.emit(
              :coap_registry_registered,
              registry: self,
              value: value,
              name: name,
              symbol: symbol,
              rfc: rfc
            )
          end

          # Get human-readable name for a value
          #
          # @param value [Integer] The numeric value
          # @return [String, nil] The name, or nil if not found
          def name_for(value)
            @mutex.synchronize { registry[value]&.dig(:name) }
          end

          # Get numeric value for a name or symbol
          #
          # @param key [String, Symbol] The name or symbol
          # @return [Integer, nil] The value, or nil if not found
          def value_for(key)
            @mutex.synchronize { reverse_registry[key] }
          end

          # Get RFC reference for a value
          #
          # @param value [Integer] The numeric value
          # @return [String, nil] The RFC reference, or nil if not found
          def rfc_for(value)
            @mutex.synchronize { registry[value]&.dig(:rfc) }
          end

          # Check if a value is registered
          #
          # @param value [Integer] The value to check
          # @return [Boolean] true if registered
          def registered?(value)
            @mutex.synchronize { registry.key?(value) }
          end

          # Get all registered constants
          #
          # @return [Hash] Map of value => name
          def all
            @mutex.synchronize { registry.transform_values { |info| info[:name] } }
          end

          # Iterate over registered values
          #
          # @yield [Integer] each registered numeric value
          # @return [Enumerator] if no block given
          def each_value(&block)
            return enum_for(:each_value) unless block_given?

            # Get snapshot to avoid holding lock during iteration
            snapshot = @mutex.synchronize { registry.keys.dup }
            snapshot.each(&block)
          end

          # Get all registered values
          #
          # @return [Array<Integer>] Array of all values
          def values
            @mutex.synchronize { registry.keys.dup }
          end

          # Get registry metadata for a value
          #
          # @param value [Integer] The numeric value
          # @return [Hash, nil] Full metadata hash
          def metadata_for(value)
            @mutex.synchronize { registry[value]&.dup }
          end

          # Clear all registrations (useful for testing)
          def clear!
            @mutex.synchronize do
              registry.clear
              reverse_registry.clear
              # Remove constants (carefully)
              constants(false).each do |const_name|
                remove_const(const_name) if const_name =~ /^[A-Z_]+$/
              end
            end

            Takagi::Hooks.emit(:coap_registry_cleared, registry: self)
          end

          private

          def registry
            @registry ||= {}
          end

          def reverse_registry
            @reverse_registry ||= {}
          end
        end
      end
    end
  end
end
