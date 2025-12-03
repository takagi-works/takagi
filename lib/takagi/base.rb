# frozen_string_literal: true

require 'rack'
require 'socket'
require 'json'
require_relative 'server/multi'
require_relative 'server_registry'
require_relative 'network/registry'
require_relative 'network/udp'
require_relative 'network/tcp'
require_relative 'plugin'
require_relative 'base/plugin_management'

module Takagi
  # Base class that every Takagi based app should use.
  #
  # Provides a Sinatra-like DSL for building CoAP servers with support for:
  # - Route registration (GET, POST, PUT, DELETE, OBSERVE)
  # - Middleware stack
  # - Reactor pattern for observables/observers
  # - Multi-protocol servers (UDP, TCP)
  #
  # This class now follows Single Responsibility Principle by delegating
  # specific concerns to focused modules:
  # - ServerLifecycle: Boot, run, spawn operations
  # - MiddlewareManagement: Middleware stack configuration
  # - ReactorManagement: Observable/observer patterns
  #
  # @example Basic usage
  #   class MyAPI < Takagi::Base
  #     get '/temperature' do
  #       { value: 25.5, unit: 'C' }
  #     end
  #   end
  #
  #   MyAPI.run!
  class Base < Router
    extend ServerLifecycle
    extend MiddlewareManagement
    extend ReactorManagement
    extend PluginManagement

    # Returns the global router instance
    #
    # @return [Router] Singleton router instance
    def self.router
      @router ||= Takagi::Router.instance
    end

    # Dynamically delegate route registration methods to router
    # Generates: get, post, put, delete, fetch, etc. from CoAP::Registries::Method registry
    CoAP::Registries::Method.all.each_value do |method_name|
      method_string = method_name.split.first
      method_symbol = method_string.downcase.to_sym

      define_singleton_method(method_symbol) do |path, metadata: {}, &block|
        router.public_send(method_symbol, path, metadata: metadata, &block)
      end
    end

    # Registers an OBSERVE route in the global router (server-side)
    # Use this to make a resource observable by clients
    # @param path [String] The URL path
    # @param block [Proc] The handler function
    def self.observable(path, metadata: {}, &block)
      router.observable(path, metadata: metadata, &block)
    end

    # Configures CoRE Link Format metadata for an existing route. Handy when
    # you want to declare handlers and metadata separately (e.g., during boot).
    def self.core(path, method: :get, &block)
      router.configure_core(method.to_s.upcase, path, &block)
    end

    # Default routes for basic functionality and RFC 6690 discovery
    get '/.well-known/core', metadata: {
      rt: 'core.discovery',
      if: 'core.rd',
      ct: Takagi::Discovery::CoreLinkFormat::CONTENT_FORMAT,
      discovery: true,
      title: 'Resource Discovery'
    } do |req|
      payload = Takagi::Discovery::CoreLinkFormat.generate(router: router, request: req)
      req.to_response(
        '2.05 Content',
        payload,
        options: { CoAP::Registries::Option::CONTENT_FORMAT => Takagi::Discovery::CoreLinkFormat::CONTENT_FORMAT }
      )
    end

    get '/ping' do
      { message: 'Pong' }
    end

    post '/echo' do |req|
      body = JSON.parse(req.payload || '{}')
      { echo: body['message'] }
    rescue JSON::ParserError
      { error: 'Invalid JSON' }
    end

    # Register default server implementations
    Server::Registry.register(:udp, Takagi::Server::Udp, rfc: 'RFC 7252')
    Server::Registry.register(:tcp, Takagi::Server::Tcp, rfc: 'RFC 8323')

    # Register default transport implementations
    Network::Registry.register(:udp, Network::Udp)
    Network::Registry.register(:tcp, Network::Tcp)
  end
end
