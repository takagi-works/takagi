# frozen_string_literal: true

require_relative 'pub_sub/reactor_interaction'
require_relative 'pub_sub/transport_registry'
require_relative 'pub_sub/coap_observe'
require_relative 'pub_sub/dispatch'

module Takagi
  # The publish/subscribe vocabulary and capability model shared by every transport
  # (reactor-interactions capability): one verb table, one registry of transports, and the
  # CoAP observe binding this change ships as the first registered transport.
  module PubSub
    # The default CoAP observe binding, registered once at load (idempotent).
    TransportRegistry.register_defaults

    # The verb dispatch surface: {Dispatch.dispatch} resolves the transport and verb and
    # refuses capabilities the transport cannot honour.
    def self.dispatch(...) = Dispatch.dispatch(...)

    # The declaration-time refusal surface: validates options against the transport's
    # declared capabilities without dispatching.
    def self.validate_request!(...) = Dispatch.validate!(...)
  end
end
