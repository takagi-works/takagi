# frozen_string_literal: true

require 'uri'
require 'json'

module Takagi
  # Base class for Takagi clients, providing common functionality
  # for both UDP (CoAP) and TCP (CoAP over TCP) clients.
  #
  # This class defines the common interface and lifecycle management
  # that all Takagi clients should follow.
  class ClientBase
    attr_reader :server_uri, :timeout, :callbacks

    # Initializes the base client
    # @param server_uri [String] URL of the Takagi server
    # @param timeout [Integer] Maximum time to wait for a response
    def initialize(server_uri, timeout: 5)
      @server_uri = URI(server_uri)
      @timeout = timeout
      @callbacks = {}
      @closed = false
    end

    # Registers a callback for a given event
    # @param event [Symbol] Event name (e.g., :response)
    # @param callback [Proc] Callback function to handle the event
    def on(event, &callback)
      @callbacks[event] = callback
    end

    # Sends a GET request
    # @param path [String] Resource path
    # @param options [Hash] CoAP options (e.g. { 17 => 50 } for Accept=application/json)
    # @param type [Integer, nil] CoAP message type (CON/NON/ACK/RST). Defaults to CON.
    # @param callback [Proc] (optional) Callback function for processing the response
    def get(path, options: {}, type: nil, &block)
      request(:get, path, nil, options: options, type: type, &block)
    end

    # Sends a POST request
    # @param path [String] Resource path
    # @param payload [String, Hash] Data to send (Hash is JSON-encoded automatically)
    # @param options [Hash] CoAP options (e.g. { 12 => 50 } for Content-Format=application/json)
    # @param type [Integer, nil] CoAP message type
    # @param callback [Proc] (optional) Callback function for processing the response
    def post(path, payload = nil, options: {}, type: nil, &block)
      request(:post, path, payload, options: options, type: type, &block)
    end

    # Sends a PUT request
    # @param path [String] Resource path
    # @param payload [String, Hash] Data to send
    # @param options [Hash] CoAP options
    # @param type [Integer, nil] CoAP message type
    # @param callback [Proc] (optional) Callback function for processing the response
    def put(path, payload = nil, options: {}, type: nil, &block)
      request(:put, path, payload, options: options, type: type, &block)
    end

    # Sends a DELETE request
    # @param path [String] Resource path
    # @param options [Hash] CoAP options
    # @param type [Integer, nil] CoAP message type
    # @param callback [Proc] (optional) Callback function for processing the response
    def delete(path, options: {}, type: nil, &block)
      request(:delete, path, nil, options: options, type: type, &block)
    end

    # Sends an OBSERVE request (RFC 7641). The Observe option is added automatically;
    # additional CoAP options can be supplied via `options:`.
    # @param path [String] Resource path
    # @param options [Hash] CoAP options (Observe is injected automatically)
    # @param callback [Proc] (optional) Callback function for processing notifications
    def observe(path, options: {}, &block)
      merged = { Takagi::CoAP::Registries::Option::OBSERVE => 0 }.merge(options)
      request(:get, path, nil, options: merged, &block)
    end

    # Sends a POST request with JSON payload (convenience method)
    # @param path [String] Resource path
    # @param data [Hash, Array] Data to encode as JSON
    # @param options [Hash] CoAP options
    # @param callback [Proc] (optional) Callback function for processing the response
    def post_json(path, data, options: {}, &block)
      cf = Takagi::CoAP::Registries::ContentFormat::JSON
      merged = { Takagi::CoAP::Registries::Option::CONTENT_FORMAT => cf }.merge(options)
      request(:post, path, JSON.generate(data), options: merged, &block)
    end

    # Sends a PUT request with JSON payload (convenience method)
    def put_json(path, data, options: {}, &block)
      cf = Takagi::CoAP::Registries::ContentFormat::JSON
      merged = { Takagi::CoAP::Registries::Option::CONTENT_FORMAT => cf }.merge(options)
      request(:put, path, JSON.generate(data), options: merged, &block)
    end

    # Sends a GET request and automatically parses JSON response (convenience method)
    def get_json(path, options: {}, &block)
      cf = Takagi::CoAP::Registries::ContentFormat::JSON
      merged = { Takagi::CoAP::Registries::Option::ACCEPT => cf }.merge(options)
      if block_given?
        get(path, options: merged) do |response|
          data = response.is_a?(String) ? parse_json_response(response) : response.json
          block.call(data)
        end
      else
        result = nil
        get(path, options: merged) { |response| result = response.is_a?(String) ? parse_json_response(response) : response.json }
        result
      end
    end

    # Closes the client and releases any resources.
    # This should be called when the client is no longer needed to prevent
    # resource leaks in long-running processes.
    #
    # Subclasses should override this method to perform specific cleanup
    # and then call super.
    def close
      return if @closed

      cleanup_resources
      @closed = true
    end

    # Check if the client has been closed
    # @return [Boolean] true if the client is closed
    def closed?
      @closed
    end

    # Creates a new client and yields it to the block, ensuring it's closed afterward.
    # This is the recommended way to use clients to prevent resource leaks.
    #
    # @param server_uri [String] URL of the Takagi server
    # @param timeout [Integer] Maximum time to wait for a response
    # @param options [Hash] Additional options passed to the subclass constructor
    # @yield [client] Gives the client to the block
    # @return [Object] The return value of the block
    #
    # @example
    #   Takagi::Client.open('coap://localhost:5683') do |client|
    #     client.get('/temperature')
    #   end
    def self.open(server_uri, timeout: 5, **options, &block)
      client = new(server_uri, timeout: timeout, **options)
      block.call(client)
    ensure
      client&.close
    end

    protected

    # Subclasses must implement this method to perform the actual request
    # @param method [Symbol] HTTP method (:get, :post, :put, :delete)
    # @param path [String] Resource path
    # @param payload [String] (optional) Data for POST/PUT requests
    # @param options [Hash] (optional) CoAP options { option_number => value }
    # @param type [Integer, nil] (optional) CoAP message type
    # @param callback [Proc] (optional) Callback function for processing the response
    def request(_method, _path, _payload = nil, options: {}, type: nil, &_callback)
      raise NotImplementedError, "#{self.class} must implement #request"
    end

    # Subclasses can override this to perform specific cleanup
    # Called by #close before marking the client as closed
    def cleanup_resources
      # Default: no-op
    end

    # Delivers a response using the callback or registered callback
    # Wraps raw response data in a Response object for convenience
    # @param response_data [String] The response data to deliver
    # @param callback [Proc] Optional callback for this specific request
    def deliver_response(response_data, &callback)
      # Wrap response in Response object for better DX
      require_relative 'client/response'
      response = Client::Response.new(response_data)

      return callback.call(response) if callback
      return @callbacks[:response].call(response) if @callbacks[:response]

      # Default: print response details
      if response.success?
        puts "[#{response.code_name}] #{response.payload}"
      else
        puts "[ERROR #{response.code_name}] #{response.payload}"
      end
    end

    # Helper to parse JSON response from raw data
    # @param response_data [String] Raw response data
    # @return [Hash, Array, nil] Parsed JSON or nil
    def parse_json_response(response_data)
      inbound = Takagi::Message::Inbound.new(response_data)
      return nil unless inbound.payload

      JSON.parse(inbound.payload)
    rescue JSON::ParserError
      nil
    end
  end
end
