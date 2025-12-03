# frozen_string_literal: true

module Takagi
  module CoAP
    # Utility methods for working with CoAP codes.
    #
    # Provides conversion between different code representations and
    # lookups across all registries.
    module CodeHelpers
      # Convert a code to its human-readable string representation
      #
      # @param code [Integer, String, Symbol] Code to convert
      # @return [String] Human-readable code string
      #
      # @example
      #   CodeHelpers.to_string(69)      # => "2.05 Content"
      #   CodeHelpers.to_string(:get)    # => "GET"
      #   CodeHelpers.to_string("2.05")  # => "2.05 Content"
      def self.to_string(code)
        case code
        when Integer
          # Try method registry first
          if code < 32
            Registries::Method.name_for(code) || numeric_to_string(code)
          # Try signaling registry for 7.xx codes
          elsif code >= 224
            Registries::Signaling.name_for(code) || numeric_to_string(code)
          # Try response registry
          elsif code >= 64
            Registries::Response.name_for(code) || numeric_to_string(code)
          else
            numeric_to_string(code)
          end
        when Symbol
          # Try method registry
          Registries::Method.value_for(code)&.then { |v| Registries::Method.name_for(v) } ||
            # Try response registry
            Registries::Response.value_for(code)&.then { |v| Registries::Response.name_for(v) } ||
            code.to_s
        when String
          # If already in dotted format, try to lookup
          if code =~ /^(\d)\.(\d{2})$/
            val = string_to_numeric(code)
            Registries::Response.name_for(val) || code
          else
            code
          end
        else
          code.to_s
        end
      end

      # Convert a code to its numeric representation
      #
      # @param code [Integer, String, Symbol] Code to convert
      # @return [Integer] Numeric code
      #
      # @example
      #   CodeHelpers.to_numeric(:get)       # => 1
      #   CodeHelpers.to_numeric("2.05")     # => 69
      #   CodeHelpers.to_numeric("2.05 Content")   # => 69
      #   CodeHelpers.to_numeric(:content)   # => 69
      def self.to_numeric(code)
        case code
        when Integer
          code
        when Symbol
          Registries::Method.value_for(code) || Registries::Response.value_for(code) || Registries::Signaling.value_for(code) || 0
        when String
          # Handle "2.05" or "2.05 Content" formats
          if code =~ /^(\d)\.(\d{2})/
            string_to_numeric("#{::Regexp.last_match(1)}.#{::Regexp.last_match(2)}")
          else
            Registries::Method.value_for(code.downcase.to_sym) ||
              Registries::Response.value_for(code.downcase.to_sym) ||
              0
          end
        else
          0
        end
      end

      # Convert numeric code to dotted string format (e.g., 69 => "2.05")
      #
      # @param code [Integer] Numeric code
      # @return [String] Dotted format string
      def self.numeric_to_string(code)
        class_num = code / 32
        detail_num = code % 32
        "#{class_num}.#{detail_num.to_s.rjust(2, '0')}"
      end

      # Convert dotted string to numeric code (e.g., "2.05" => 69)
      #
      # @param code_string [String] Dotted format string
      # @return [Integer] Numeric code
      def self.string_to_numeric(code_string)
        return 0 unless code_string =~ /^(\d)\.(\d{2})$/

        class_num = ::Regexp.last_match(1).to_i
        detail_num = ::Regexp.last_match(2).to_i
        (class_num * 32) + detail_num
      end

      # Check if a code represents success
      #
      # @param code [Integer, String, Symbol] Code to check
      # @return [Boolean] true if success code (2.xx)
      def self.success?(code)
        numeric = to_numeric(code)
        Registries::Response.success?(numeric)
      end

      # Check if a code represents an error
      #
      # @param code [Integer, String, Symbol] Code to check
      # @return [Boolean] true if error code (4.xx or 5.xx)
      def self.error?(code)
        numeric = to_numeric(code)
        Registries::Response.error?(numeric)
      end

      # Check if a code represents a client error
      #
      # @param code [Integer, String, Symbol] Code to check
      # @return [Boolean] true if client error (4.xx)
      def self.client_error?(code)
        numeric = to_numeric(code)
        Registries::Response.client_error?(numeric)
      end

      # Check if a code represents a server error
      #
      # @param code [Integer, String, Symbol] Code to check
      # @return [Boolean] true if server error (5.xx)
      def self.server_error?(code)
        numeric = to_numeric(code)
        Registries::Response.server_error?(numeric)
      end

      # Lookup code in all registries
      #
      # @param code [Integer, String, Symbol] Code to lookup
      # @return [Hash, nil] Registry information
      def self.lookup(code)
        numeric = to_numeric(code)
        return nil if numeric.zero?

        {
          value: numeric,
          string: numeric_to_string(numeric),
          name: to_string(numeric),
          type: code_type(numeric),
          rfc: find_rfc(numeric)
        }
      end

      # Get the type of code (method, response, or unknown)
      #
      # @param code [Integer] Numeric code
      # @return [Symbol] :method, :response, or :unknown
      def self.code_type(code)
        if code < 32
          :method
        elsif code.between?(64, 191)
          :response
        elsif code.between?(224, 255)
          :signaling
        else
          :unknown
        end
      end

      # Find RFC reference for a code
      #
      # @param code [Integer] Numeric code
      # @return [String, nil] RFC reference
      def self.find_rfc(code)
        Registries::Method.rfc_for(code) || Registries::Response.rfc_for(code) || Registries::Signaling.rfc_for(code)
      end

      # Get all registered codes across all registries
      #
      # @return [Hash] Map of value => name for all codes
      def self.all
        Registries::Method.all.merge(Registries::Response.all)
      end
    end
  end
end
