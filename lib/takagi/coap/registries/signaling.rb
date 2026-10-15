# frozen_string_literal: true

module Takagi
  module CoAP
    module Registries
      # CoAP Signaling Code Registry (RFC 8323 §5)
      #
      # Registry for CoAP over TCP/TLS signaling messages.
      # Signaling messages use codes in the 7.xx range.
      #
      # @example Using signaling codes
      #   Takagi::CoAP::Registries::Signaling::CSM    # => 225 (7.01)
      #   Takagi::CoAP::Registries::Signaling::PING   # => 226 (7.02)
      #
      # @example Looking up signaling message names
      #   Takagi::CoAP::Registries::Signaling.name_for(225)  # => "7.01 CSM"
      class Signaling < Base
        # RFC 8323 §5.1 - Signaling Codes
        register(225, '7.01 CSM', :csm, rfc: 'RFC 8323 §5.3')            # Capabilities and Settings Message
        register(226, '7.02 Ping', :ping, rfc: 'RFC 8323 §5.4')          # Ping
        register(227, '7.03 Pong', :pong, rfc: 'RFC 8323 §5.4')          # Pong
        register(228, '7.04 Release', :release, rfc: 'RFC 8323 §5.5')    # Release
        register(229, '7.05 Abort', :abort, rfc: 'RFC 8323 §5.6')        # Abort

        # Check if code is a signaling code
        # @param code [Integer] Code to check
        # @return [Boolean] true if signaling code (7.xx)
        def self.signaling?(code)
          (224..255).include?(code) && registered?(code)
        end
      end
    end
  end
end