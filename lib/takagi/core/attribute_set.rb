# frozen_string_literal: true

require_relative '../block_wise/attribute_set'

module Takagi
  module Core
    # Encapsulates CoRE Link Format attribute handling for a single route.
    # The DSL is shared between request-time handlers and boot-time helpers,
    # so changes applied here are idempotent and safe to call repeatedly.
    class AttributeSet
      CONTENT_FORMATS = {
        'text/plain' => 0,
        'application/link-format' => 40,
        'application/xml' => 41,
        'application/octet-stream' => 42,
        'application/exi' => 47,
        'application/json' => 50,
        'application/cbor' => 60
      }.freeze

      REMOVE = Object.new

      attr_reader :metadata

      def initialize(metadata)
        @metadata = metadata
        @overrides = {}
        @block_wise = BlockWise::AttributeSet.new
      end

      # Evaluates a block that configures any mix of CoRE attributes.
      # Accepts the same DSL as the runtime helpers exposed in RouteContext.
      def core(&block)
        instance_exec(&block) if block
      end

      # Declares the block-wise settings for THIS route, in the same readable style as {#core}.
      #
      # The values are staged on a {BlockWise::AttributeSet} and persisted into the route metadata
      # under
      # :block_wise by {#apply!}. The BlockWise middleware overlays them onto the global
      # `block_wise` configuration for this route alone, so a route can bound its own transfer
      # without another route inheriting the bound.
      def blockwise(&block)
        return unless block

        @block_wise.declared!
        @block_wise.instance_exec(&block)
      end

      def ct(value)
        metadata_override(:ct, normalize_content_format(value))
      end
      alias content_format ct

      def sz(value)
        metadata_override(:sz, value.to_i)
      end

      def title(value)
        metadata_override(:title, value.to_s)
      end

      def obs(value = true)
        metadata_override(:obs, value ? true : REMOVE)
      end
      alias observable obs

      def rt(*values)
        assign_list(:rt, values)
      end

      def interface(*values)
        assign_list(:if, values)
      end
      alias if_ interface

      def attribute(name, value)
        metadata_override(name.to_sym, value.nil? ? REMOVE : value)
      end

      # Persists staged attribute overrides back onto the route metadata.
      # Invoked automatically after request handling, but also exposed so
      # callers (e.g. Takagi::Router#configure_core) can persist updates.
      def apply!
        return if @overrides.empty? && @block_wise.empty?

        persist_overrides!
        persist_block_wise!
      end

      private

      def persist_overrides!
        @overrides.each do |key, value|
          value.equal?(REMOVE) ? metadata.delete(key) : (metadata[key] = coerced_override(value))
        end
        @overrides.clear
      end

      # Merged rather than replaced, so a `metadata: { block_wise: {...} }` declaration and a
      # `blockwise do ... end` block on the same route combine, with the block winning.
      def persist_block_wise!
        return if @block_wise.empty?

        metadata[:block_wise] = (metadata[:block_wise] || {}).merge(@block_wise.to_h)
      end

      def coerced_override(value)
        return value unless value.is_a?(Array)

        normalized = value.map(&:to_s)
        normalized.length == 1 ? normalized.first : normalized
      end

      def assign_list(key, values)
        flattened = values.flatten.compact
        return if flattened.empty?

        overrides = Array(@overrides[key])
        overrides = [] if overrides.empty?

        flattened.each do |value|
          str = value.to_s
          overrides << str unless overrides.include?(str)
        end

        @overrides[key] = overrides
      end

      def metadata_override(key, value)
        @overrides[key] = value
      end

      def normalize_content_format(value)
        case value
        when Integer
          value
        when String
          normalized = value.strip
          return normalized.to_i if normalized.match?(/\A\d+\z/)

          mapped = CONTENT_FORMATS[normalized.downcase]
          return mapped if mapped

          raise ArgumentError, "Unknown content format: #{value}"
        else
          raise ArgumentError, "Unsupported content-format value: #{value.inspect}"
        end
      end
    end
  end
end
