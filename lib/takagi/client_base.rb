# frozen_string_literal: true

require 'uri'
require 'json'
require 'securerandom'
require_relative 'coap/block_wise'

module Takagi
  # RFC 7959 block-wise transfer for clients: the Block1 upload and Block2 reassembly
  # iteration that runs on top of the transport primitives ({#build_request_message},
  # {#exchange}).
  #
  # Included into {ClientBase} and shared by every transport, so the block logic lives
  # in exactly one place: only the primitives differ per transport, and
  # {#block_wise_transport?} decides whether a transport needs block-wise transfer at all.
  module ClientBlockWiseIteration
    private

    # Sends one logical request and returns the single response the caller sees.
    #
    # Datagram transports apply both directions: a body that does not fit one block goes
    # out as a Block1 sequence, and an incoming Block2 sequence is reassembled into one
    # response. Stream transports perform one exchange per request.
    #
    # @param method [Symbol] HTTP method (:get, :post, :put, :delete)
    # @param uri [URI] Absolute request URI
    # @param token [String] Request token, reused for every block of one transfer
    # @param payload [String, Hash, nil] Request body
    # @param options [Hash] CoAP options { option_number => value }
    # @param type [Integer, nil] CoAP message type
    # @return [Takagi::Client::Response, nil] nil when the exchange timed out or failed
    def block_wise_request(method, uri, token, payload, options, type)
      raw = block_wise_exchange(method, uri, token, payload, options, type)
      return nil unless raw

      response = client_response(raw)
      return response unless block_wise_transport?

      reassemble_block2(method, uri, token, payload, options, type, response)
    end

    # Raw response of one logical request: a Block1 sequence when the body needs
    # splitting, a single exchange otherwise.
    #
    # @return [String, nil]
    def block_wise_exchange(method, uri, token, payload, options, type)
      body = block_wise_body(payload)
      return send_block1(method, uri, token, body, options, type) if body

      exchange(build_request_message(method, uri, payload, token: token, options: options, type: type), uri)
    end

    # The request body to split into Block1 blocks, or nil when one message carries it.
    #
    # @param payload [Object] caller-supplied body
    # @return [String, nil]
    def block_wise_body(payload)
      return nil unless block_wise_transport? && block_wise_enabled? && payload.is_a?(String)

      body = payload.b
      body.bytesize > block_size ? body : nil
    end

    # Sends a body that exceeds one block as a Block1 sequence (RFC 7959 §2.5).
    #
    # Every block reuses one token so the server can key the assembly, and the transfer
    # stops at the first answer that is not 2.31 Continue before the last block: that
    # response (4.13, 4.08, ...) is surfaced to the caller unchanged.
    #
    # @return [String, nil] raw response to the last block sent, or nil on timeout
    def send_block1(method, uri, token, body, options, type)
      blocks = CoAP::BlockWise.slice(body, szx: block_szx)
      blocks.each_with_index do |block, index|
        raw = exchange(block1_message(method, uri, token, options, type, block), uri)
        return nil if raw.nil?

        return raw if index == blocks.size - 1 || !continue_response?(raw)
      end
    end

    # Builds the request message carrying one Block1 block.
    #
    # @return [Object] a message responding to `#to_bytes`
    def block1_message(method, uri, token, options, type, block)
      block_options = options.merge(CoAP::Registries::Option::BLOCK1 => [block.option_value])
      build_request_message(method, uri, block.payload, token: token, options: block_options, type: type)
    end

    # Whether a raw response is 2.31 Continue (RFC 7959 §2.9.1).
    #
    # @param raw [String] raw response bytes
    # @return [Boolean]
    def continue_response?(raw)
      client_response(raw).code == CoAP::Registries::Response::CONTINUE
    end

    # Follows a Block2 response (RFC 7959 §2.4) until its M flag is clear and returns ONE
    # response carrying the reassembled representation.
    #
    # A response without a Block2 option, and a single already-complete block, come back
    # untouched. Each further NUM is requested by repeating the request with a Block2
    # option, so a stateless server reproduces the same representation (which is why the
    # body travels again). A transfer that stops before the last block, or whose blocks do
    # not line up (an out-of-order or repeated NUM, a changed SZX), raises
    # {Takagi::CoAP::BlockWise::IncompleteError} rather than returning partial data; an
    # error response to a continuation is handed to the caller as the response instead.
    #
    # @return [Takagi::Client::Response]
    def reassemble_block2(method, uri, token, payload, options, type, response)
      blocks = []
      current = response
      loop do
        block = block2_block(current)
        break if block.nil?

        blocks << block
        break unless block.more?

        current = next_block_response(method, uri, token, payload, options, type, block)
      end
      return current if blocks.empty? || current.error?
      if blocks.last.more?
        raise CoAP::BlockWise::IncompleteError, "Block2 transfer stopped at NUM #{blocks.last.num} without the last block"
      end
      return response if blocks.size == 1

      assembled = CoAP::BlockWise.join(blocks)
      assembled_options = response.options.reject { |number, _| number == CoAP::Registries::Option::BLOCK2 }
      client_response(response.raw_data, payload: assembled, options: assembled_options)
    end

    # Repeats the request with a Block2 option for the block that follows `block` and
    # returns its response.
    #
    # @return [Takagi::Client::Response]
    def next_block_response(method, uri, token, payload, options, type, block)
      option = CoAP::BlockWise::OptionValue.encode(num: block.num + 1, more: false, szx: block.szx)
      block2_options = options.merge(CoAP::Registries::Option::BLOCK2 => [option])
      raw = block_wise_exchange(method, uri, token, payload, block2_options, type)
      raise CoAP::BlockWise::IncompleteError, "no response for Block2 NUM #{block.num + 1}" if raw.nil?

      client_response(raw)
    end

    # Decodes the Block2 option payload of a response, or nil when it carries none.
    #
    # @param response [Takagi::Client::Response]
    # @return [Takagi::CoAP::BlockWise::Block, nil]
    def block2_block(response)
      raw = Array(response.options[CoAP::Registries::Option::BLOCK2]).first
      return nil if raw.nil?

      option = CoAP::BlockWise::OptionValue.decode(raw)
      CoAP::BlockWise::Block.new(num: option.num, more: option.more?, szx: option.szx, payload: response.payload.to_s.b)
    rescue CoAP::BlockWise::DecodeError
      raise CoAP::BlockWise::IncompleteError, 'malformed Block2 option in response'
    end

    # Wraps raw response bytes in a {Takagi::Client::Response}.
    #
    # @param raw [String, Takagi::Client::Response] raw bytes, or an already wrapped response
    # @param payload [String, nil] reassembled representation overriding the datagram's own
    # @param options [Hash, nil] CoAP options overriding the datagram's own
    # @return [Takagi::Client::Response]
    def client_response(raw, payload: nil, options: nil)
      require_relative 'client/response'
      return raw if raw.is_a?(Client::Response)

      Client::Response.new(raw, payload: payload, options: options, transport: response_transport)
    end

    # Transport that framed the responses this client receives, so a response is parsed
    # with its own transport's framing (UDP header/token layout or TCP length framing).
    #
    # @return [Symbol] :udp or :tcp
    def response_transport
      :udp
    end

    # @return [Object, nil] the configured `block_wise` settings
    def block_wise_settings
      Takagi.config.block_wise if Takagi.config.respond_to?(:block_wise)
    end

    # @return [Boolean] whether block-wise transfer is enabled by configuration
    def block_wise_enabled?
      !!block_wise_settings&.enabled
    end

    # @return [Integer] SZX (block size exponent) used for outgoing requests
    def block_szx
      (block_wise_settings&.szx || CoAP::BlockWise::OptionValue::MAX_SZX).to_i
    end

    # @return [Integer] block size in bytes for {#block_szx}
    def block_size
      CoAP::BlockWise::OptionValue.size_for(block_szx)
    end
  end

  # Base class for Takagi clients, providing common functionality
  # for both UDP (CoAP) and TCP (CoAP over TCP) clients.
  #
  # This class defines the common interface and lifecycle management
  # that all Takagi clients should follow, and owns the shared request path:
  # {#request} runs one logical CoAP request through the transport primitives
  # {#build_request_message} and {#exchange}, adding RFC 7959 block-wise transfer
  # where the transport needs it (see {ClientBlockWiseIteration}).
  class ClientBase
    include ClientBlockWiseIteration

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

    # Probes the peer's liveness: true when it answers this transport's liveness
    # probe within the client timeout, false when it does not.
    #
    # A liveness probe has no CoAP response behind it, so nothing is returned but a
    # boolean: UDP sends an Empty Confirmable message and looks for the Reset it
    # elicits (RFC 7252 1.2, Table 1), TCP sends a Ping signalling message and looks
    # for a Pong carrying the same token (RFC 8323 5.4). A silent, closed or
    # unreachable peer yields false rather than an exception.
    #
    # @return [Boolean] true when the peer answered the probe
    def ping
      transport_ping
    rescue StandardError => e
      Takagi.logger.debug "#{self.class} ping failed: #{e.message}"
      false
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

    # Sends one logical CoAP request and delivers the single response the caller sees.
    #
    # Block-wise transfer is transparent here: a large body is uploaded as a Block1
    # sequence and a Block2 response is reassembled by {ClientBlockWiseIteration} on
    # transports that need it, so callers keep using one request and one response.
    #
    # @param method [Symbol] HTTP method (:get, :post, :put, :delete)
    # @param path [String] Resource path
    # @param payload [String, Hash, nil] Data for POST/PUT requests
    # @param options [Hash] CoAP options { option_number => value }
    # @param type [Integer, nil] CoAP message type
    # @param callback [Proc] Optional callback for this request's response
    # @return [Takagi::Client::Response, nil] the response, or nil on timeout/transport error
    # @raise [Takagi::CoAP::BlockWise::IncompleteError] when a Block2 sequence is incomplete
    def request(method, path, payload = nil, options: {}, type: nil, &callback)
      response = perform_request(method, path, payload, options: options, type: type)
      deliver_response(response, &callback) if response
      response
    rescue Takagi::CoAP::BlockWise::Error
      raise
    rescue StandardError => e
      Takagi.logger.error "#{self.class} error: #{e.message}"
      nil
    end

    # Builds a transport-specific request message for one logical CoAP request.
    #
    # Subclasses must implement this; the block-wise iteration above it stays transport
    # agnostic.
    #
    # @param method [Symbol] HTTP method (:get, :post, :put, :delete)
    # @param uri [URI] Absolute request URI
    # @param payload [String, Hash, nil] Request body
    # @param token [String] Request token, constant across one block-wise transfer
    # @param options [Hash] CoAP options { option_number => value }
    # @param type [Integer, nil] CoAP message type
    # @return [Object] a message responding to `#to_bytes`
    def build_request_message(_method, _uri, _payload, token:, options: {}, type: nil)
      raise NotImplementedError, "#{self.class} must implement #build_request_message"
    end

    # Sends one encoded message and returns the raw response bytes.
    #
    # Subclasses must implement this with their transport's delivery semantics
    # (retransmission for UDP, length framing for TCP).
    #
    # @param message [Object] message built by {#build_request_message}
    # @param uri [URI] Absolute request URI
    # @return [String, nil] raw CoAP response, or nil when the exchange timed out or failed
    def exchange(_message, _uri)
      raise NotImplementedError, "#{self.class} must implement #exchange"
    end

    # Sends this transport's liveness probe and reports whether the peer answered it.
    #
    # Subclasses must implement this, because both the probe and the reply that
    # proves liveness differ per transport; see {#ping} for the two shapes.
    #
    # @return [Boolean] true when the peer answered the probe
    def transport_ping
      raise NotImplementedError, "#{self.class} must implement #transport_ping"
    end

    # Whether this transport applies RFC 7959 block-wise iteration.
    #
    # Datagram transports (UDP) do, because one message must fit one datagram. Stream
    # transports (TCP) carry a whole message in one frame, and Takagi deliberately does
    # not implement RFC 8323 block-wise transfer over TCP, so they exchange one message.
    #
    # @return [Boolean]
    def block_wise_transport?
      false
    end

    # Sends one logical request end to end and returns the response the caller sees.
    #
    # @return [Takagi::Client::Response, nil]
    def perform_request(method, path, payload, options:, type:)
      uri = URI.join(server_uri.to_s, path)
      block_wise_request(method, uri, SecureRandom.hex(4), payload, options, type)
    end

    # Subclasses can override this to perform specific cleanup
    # Called by #close before marking the client as closed
    def cleanup_resources
      # Default: no-op
    end

    # Delivers a response using the callback or registered callback
    # Wraps raw response data in a Response object for convenience
    # @param response_data [String, Takagi::Client::Response] The response to deliver
    # @param callback [Proc] Optional callback for this specific request
    def deliver_response(response_data, &callback)
      # Wrap response in Response object for better DX
      response = client_response(response_data)

      return callback.call(response) if callback
      return @callbacks[:response].call(response) if @callbacks[:response]

      # Default: print response details
      if response.rejected?
        puts "[REJECTED #{response.code_name}] #{response.payload}"
      elsif response.acknowledged_without_response?
        puts "[ACKNOWLEDGED #{response.code_name}] #{response.payload}"
      elsif response.success?
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
