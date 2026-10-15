# frozen_string_literal: true

module Takagi
  module CoAP
    module Registries
      # CoAP Option Number Registry (RFC 7252 §5.10)
      #
      # Extensible registry for CoAP option numbers.
      # Plugins can register custom options without modifying core code.
      #
      # @example Using predefined options
      #   Takagi::CoAP::Registries::Option::URI_PATH         # => 11
      #   Takagi::CoAP::Registries::Option::CONTENT_FORMAT   # => 12
      #
      # @example Registering a custom option
      #   Takagi::CoAP::Registries::Option.register(65000, 'Custom-Option', :custom_option)
      #   Takagi::CoAP::Registries::Option::CUSTOM_OPTION  # => 65000
      #
      # @example Looking up option names
      #   Takagi::CoAP::Registries::Option.name_for(11)  # => "Uri-Path"
      class Option < Base
        # RFC 7252 §5.10.1 - Option Definitions
        register(1, 'If-Match', :if_match, rfc: 'RFC 7252 §5.10.8.1')
        register(3, 'Uri-Host', :uri_host, rfc: 'RFC 7252 §5.10.1')
        register(4, 'ETag', :etag, rfc: 'RFC 7252 §5.10.6')
        register(5, 'If-None-Match', :if_none_match, rfc: 'RFC 7252 §5.10.8.2')
        register(6, 'Observe', :observe, rfc: 'RFC 7641 §2')
        register(7, 'Uri-Port', :uri_port, rfc: 'RFC 7252 §5.10.1')
        register(8, 'Location-Path', :location_path, rfc: 'RFC 7252 §5.10.7')
        register(11, 'Uri-Path', :uri_path, rfc: 'RFC 7252 §5.10.1')
        register(12, 'Content-Format', :content_format, rfc: 'RFC 7252 §5.10.3')
        register(14, 'Max-Age', :max_age, rfc: 'RFC 7252 §5.10.5')
        register(15, 'Uri-Query', :uri_query, rfc: 'RFC 7252 §5.10.2')
        register(17, 'Accept', :accept, rfc: 'RFC 7252 §5.10.4')
        register(20, 'Location-Query', :location_query, rfc: 'RFC 7252 §5.10.7')
        register(35, 'Proxy-Uri', :proxy_uri, rfc: 'RFC 7252 §5.10.2')
        register(39, 'Proxy-Scheme', :proxy_scheme, rfc: 'RFC 7252 §5.10.2')
        register(60, 'Size1', :size1, rfc: 'RFC 7252 §5.10.9')

        register(23, 'Block2', :block2, rfc: 'RFC 7959 §2.2')
        register(27, 'Block1', :block1, rfc: 'RFC 7959 §2.1')
        register(28, 'Size2', :size2, rfc: 'RFC 7959 §4')

        # Check if an option is critical
        # Critical options must be understood by the recipient
        # @param number [Integer] Option number
        # @return [Boolean] true if critical
        def self.critical?(number)
          number.allbits?(1)
        end

        # Check if an option is unsafe to forward
        # @param number [Integer] Option number
        # @return [Boolean] true if unsafe
        def self.unsafe?(number)
          number.allbits?(2)
        end

        # Check if an option has NoCacheKey property
        # @param number [Integer] Option number
        # @return [Boolean] true if NoCacheKey
        def self.no_cache_key?(number)
          (number & 0x1E) == 0x1C
        end

        # Check if option number is valid
        # @param number [Integer] Option number
        # @return [Boolean] true if valid
        def self.valid?(number)
          number.between?(0, 65_535)
        end
      end
    end
  end
end
