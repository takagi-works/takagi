# frozen_string_literal: true

module Takagi
  # CoAP Protocol implementation following RFC 7252 and related RFCs.
  #
  # This module provides a registry-based system for CoAP protocol constants.
  # Plugins and extensions can register additional constants without modifying
  # core code by using the registries under {Takagi::CoAP::Registries}.
  #
  # @example Registering a custom response code
  #   Takagi::CoAP::Registries::Response.register(231, '7.01 Custom Code', :custom_code)
  #
  # @example Using registered constants
  #   code = Takagi::CoAP::Registries::Response::CONTENT  # => 69
  #   Takagi::CoAP::Registries::Response.name_for(69)     # => "2.05 Content"
  module CoAP
    # Default CoAP port (RFC 7252 §6.1)
    DEFAULT_PORT = 5683

    # Default CoAPS (secure) port (RFC 7252 §6.2)
    DEFAULT_SECURE_PORT = 5684

    # CoAP version (RFC 7252 §3)
    VERSION = 1
  end
end

# Load registries
require_relative 'coap/registries/base'
require_relative 'coap/registries/method'
require_relative 'coap/registries/response'
require_relative 'coap/registries/option'
require_relative 'coap/registries/content_format'
require_relative 'coap/registries/message_type'
require_relative 'coap/registries/signaling'

require_relative 'coap/code_helpers'
