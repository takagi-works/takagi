# frozen_string_literal: true

module Takagi
  module CoAP
    module Registries
      # CoAP Response Code Registry (RFC 7252 §12.1.2)
      #
      # Extensible registry for CoAP response codes.
      # Plugins can register custom response codes without modifying core code.
      #
      # @example Using predefined codes
      #   Takagi::CoAP::Registries::Response::CONTENT    # => 69 (2.05)
      #   Takagi::CoAP::Registries::Response::NOT_FOUND  # => 132 (4.04)
      #
      # @example Registering a custom code
      #   Takagi::CoAP::Registries::Response.register(231, '7.07 Custom', :custom)
      #   Takagi::CoAP::Registries::Response::CUSTOM  # => 231
      #
      # @example Looking up code names
      #   Takagi::CoAP::Registries::Response.name_for(69)  # => "2.05 Content"
      class Response < Base
        # Success 2.xx (RFC 7252 §5.9.1)
        register(65, '2.01 Created', :created, rfc: 'RFC 7252 §5.9.1.1')
        register(66, '2.02 Deleted', :deleted, rfc: 'RFC 7252 §5.9.1.2')
        register(67, '2.03 Valid', :valid, rfc: 'RFC 7252 §5.9.1.3')
        register(68, '2.04 Changed', :changed, rfc: 'RFC 7252 §5.9.1.4')
        register(69, '2.05 Content', :content, rfc: 'RFC 7252 §5.9.1.5')
        register(95, '2.31 Continue', :continue, rfc: 'RFC 7959 §2.9.1')

        # Client Error 4.xx (RFC 7252 §5.9.2)
        register(128, '4.00 Bad Request', :bad_request, rfc: 'RFC 7252 §5.9.2.1')
        register(129, '4.01 Unauthorized', :unauthorized, rfc: 'RFC 7252 §5.9.2.2')
        register(130, '4.02 Bad Option', :bad_option, rfc: 'RFC 7252 §5.9.2.3')
        register(131, '4.03 Forbidden', :forbidden, rfc: 'RFC 7252 §5.9.2.4')
        register(132, '4.04 Not Found', :not_found, rfc: 'RFC 7252 §5.9.2.5')
        register(133, '4.05 Method Not Allowed', :method_not_allowed, rfc: 'RFC 7252 §5.9.2.6')
        register(134, '4.06 Not Acceptable', :not_acceptable, rfc: 'RFC 7252 §5.9.2.7')
        register(140, '4.12 Precondition Failed', :precondition_failed, rfc: 'RFC 7252 §5.9.2.9')
        register(136, '4.08 Request Entity Incomplete', :request_entity_incomplete, rfc: 'RFC 7959 §2.9.2')
        register(141, '4.13 Request Entity Too Large', :request_entity_too_large, rfc: 'RFC 7252 §5.9.2.10')
        register(143, '4.15 Unsupported Content-Format', :unsupported_content_format, rfc: 'RFC 7252 §5.9.2.11')

        # Server Error 5.xx (RFC 7252 §5.9.3)
        register(160, '5.00 Internal Server Error', :internal_server_error, rfc: 'RFC 7252 §5.9.3.1')
        register(161, '5.01 Not Implemented', :not_implemented, rfc: 'RFC 7252 §5.9.3.2')
        register(162, '5.02 Bad Gateway', :bad_gateway, rfc: 'RFC 7252 §5.9.3.3')
        register(163, '5.03 Service Unavailable', :service_unavailable, rfc: 'RFC 7252 §5.9.3.4')
        register(164, '5.04 Gateway Timeout', :gateway_timeout, rfc: 'RFC 7252 §5.9.3.5')
        register(165, '5.05 Proxying Not Supported', :proxying_not_supported, rfc: 'RFC 7252 §5.9.3.6')

        # Get the response class (2, 4, 5, etc.)
        # @param code [Integer] Response code
        # @return [Integer] Class number
        def self.class_for(code)
          code / 32
        end

        # Check if code is a success (2.xx)
        # @param code [Integer] Response code
        # @return [Boolean] true if success
        def self.success?(code)
          class_for(code) == 2
        end

        # Check if code is a client error (4.xx)
        # @param code [Integer] Response code
        # @return [Boolean] true if client error
        def self.client_error?(code)
          class_for(code) == 4
        end

        # Check if code is a server error (5.xx)
        # @param code [Integer] Response code
        # @return [Boolean] true if server error
        def self.server_error?(code)
          class_for(code) == 5
        end

        # Check if code is any error (4.xx or 5.xx)
        # @param code [Integer] Response code
        # @return [Boolean] true if error
        def self.error?(code)
          client_error?(code) || server_error?(code)
        end

        # Check if code is a valid response code
        # @param code [Integer] Code to check
        # @return [Boolean] true if valid response code
        def self.valid?(code)
          code.between?(64, 191) && registered?(code)
        end
      end
    end
  end
end
