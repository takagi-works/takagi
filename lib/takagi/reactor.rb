# frozen_string_literal: true

require_relative 'observable/reactor'

module Takagi
  # Backward compatibility alias for Observable::Reactor
  #
  # @deprecated Use {Observable::Reactor} instead. This alias will be removed in v2.0.0
  #
  # The new Observable::Reactor provides:
  # - Thread pool support for parallel execution
  # - Event-driven notifications via Bus
  # - Hybrid polling + push modes
  # - Better resource management
  #
  # @example Migration
  #   # Old
  #   reactor = Takagi::Reactor.new
  #
  #   # New
  #   reactor = Takagi::Observable::Reactor.new(threads: 4)
  Reactor = Observable::Reactor
end
