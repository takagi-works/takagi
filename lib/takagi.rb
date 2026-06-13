# frozen_string_literal: true

require 'zeitwerk'

# Coap and Ruby in Sinatra like package
module Takagi
  class Error < StandardError; end

  def self.config
    @config ||= Takagi::Config.new
  end

  def self.logger
    @logger ||= Takagi::Logger.new(level: ::Logger::INFO)
  end

  loader = Zeitwerk::Loader.for_gem
  # Configure inflector for CoAP (Constrained Application Protocol),
  # CBOR (Concise Binary Object Representation), and EventBus utilities
  loader.inflector.inflect(
    'coap' => 'CoAP',
    'cbor' => 'CBOR',
    'coap_bridge' => 'CoAPBridge',
    'lru_cache' => 'LRUCache'
  )
  # Ignore version file - VERSION constant is manually defined
  loader.ignore("#{__dir__}/takagi/cbor/version.rb")
  loader.setup
  loader.eager_load
end
