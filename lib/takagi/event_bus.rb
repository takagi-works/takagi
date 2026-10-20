# frozen_string_literal: true

require_relative 'bus'

module Takagi
  # Backward compatibility alias for Bus
  #
  # @deprecated Use {Bus} instead. This alias will be removed in v2.0.0
  EventBus = Bus
end

require_relative 'event_bus/async_executor'
require_relative 'event_bus/lru_cache'
require_relative 'event_bus/future'
require_relative 'event_bus/coap_bridge'
require_relative 'event_bus/observer_cleanup'
require_relative 'event_bus/message_buffer'
