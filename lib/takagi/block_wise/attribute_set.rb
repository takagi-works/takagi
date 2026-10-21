# frozen_string_literal: true

module Takagi
  module BlockWise
    # The per-route block-wise settings a handler declares in a `blockwise do ... end` block.
    #
    # Key for key the global `block_wise` configuration, under shorter readable names, with each
    # global spelling kept as an alias so code and docs may use either.
    #
    # Declaring the block IS the opt-in: unless the block says otherwise the settings carry
    # `enabled: true`, so a route can turn block-wise on against a globally disabled feature. A
    # route that declares nothing keeps no settings at all, and the global value governs it alone.
    #
    # A value the middleware cannot use is refused here with a warning rather than raised: the
    # boot-time metadata pass runs the handler inside a rescue, so a raise would silently drop every
    # other setting declared beside it.
    class AttributeSet
      SZX_RANGE = (0..6)

      def initialize
        @values = {}
        @declared = false
      end

      # Records that the route declared a block-wise block at all, which is what turns the feature
      # on for it. Called by `Takagi::Core::AttributeSet#blockwise` before the block runs.
      def declared!
        @declared = true
      end

      def enabled(value = true) = @values[:enabled] = value ? true : false

      def szx(value)
        exponent = coerce(:szx, value)
        return if exponent.nil?

        unless SZX_RANGE.cover?(exponent)
          Takagi.logger.warn("blockwise szx #{value.inspect} is outside #{SZX_RANGE}; ignored")
          return
        end

        @values[:szx] = exponent
      end

      def max_bytes(value) = @values[:max_assembled_bytes] = coerce(:max_bytes, value)
      alias max_assembled_bytes max_bytes

      def ttl(value) = @values[:assembly_ttl] = coerce(:ttl, value)
      alias assembly_ttl ttl

      def max_assemblies(value) = @values[:max_concurrent_assemblies] = coerce(:max_assemblies, value)
      alias max_concurrent_assemblies max_assemblies

      def empty? = @values.empty? && !@declared

      # The settings to persist.
      #
      # The implied `enabled: true` is merged UNDER whatever the block set, so a block that writes
      # `enabled false` still wins - the declaration turns the feature on only in the absence of a
      # decision.
      def to_h
        return @values.dup unless @declared

        { enabled: true }.merge(@values)
      end

      private

      def coerce(name, value)
        Integer(value)
      rescue ArgumentError, TypeError
        Takagi.logger.warn("blockwise #{name} #{value.inspect} is not an integer; ignored")
        nil
      end
    end
  end
end
