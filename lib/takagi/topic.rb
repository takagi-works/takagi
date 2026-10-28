# frozen_string_literal: true

require_relative 'observer/registry'
require_relative 'observable/emitter'
require_relative 'pub_sub/transport_registry'

module Takagi
  # A resource with ONE current representation (design D1).
  #
  # Topics are declared where the service is declared - a controller, an application or a
  # reactor - and are registered with the service's router. The declaration block runs ONCE,
  # at declaration time, producing the initial representation (the emitter it receives wires
  # bus events and pushes); serving a request never re-runs the producer. A plain GET reads
  # the current representation without registering; a GET carrying Observe: 0 registers the
  # client (RFC 7641 §4.1); a GET with the observation's token and Observe: 1 deregisters it
  # (§3.6, §4.1). The representation is what the next notification announces: publishing a
  # DIFFERENT value changes the served representation and notifies observers, publishing the
  # current value changes nothing and notifies nobody, and notification is never driven by an
  # interval (design D9).
  class Topic
    DEFAULT_CONTENT_FORMAT = CoAP::Registries::ContentFormat::JSON

    # Raised when the same topic path is declared twice on one surface.
    class DuplicateTopicError < StandardError; end

    attr_reader :path, :content_format, :emitter

    # @param path [String] the resource path
    # @param content_format [Integer] the Content-Format serving and notifications carry
    # @yield [emitter] produces the initial representation; the emitter pushes later ones
    def initialize(path, content_format: DEFAULT_CONTENT_FORMAT, &producer)
      @path = path
      @content_format = content_format
      @mutex = Mutex.new
      @deleted = false
      @sequence = 0
      @value = nil
      @emitter = Observable::Emitter.new(path, topic: self)
      @value = producer&.call(@emitter)
    end

    # @return [Object] the current representation
    def current_value
      @mutex.synchronize { @value }
    end

    # @return [Integer] the resource's current obsolete sequence value
    def sequence
      @mutex.synchronize { @sequence }
    end

    # @return [Boolean]
    def deleted?
      @mutex.synchronize { @deleted }
    end

    # Local publication (design D8): a different representation becomes the one served to
    # later reads and notifies observers; publishing the current representation changes
    # nothing and notifies nobody.
    #
    # @param new_value [Object]
    # @return [Boolean] true when the publication changed the representation
    def publish(new_value)
      changed = @mutex.synchronize do
        next false if @deleted
        next false if @value == new_value

        @value = new_value
        @sequence = (@sequence + 1) & 0xFFFFFF
        true
      end

      Observer::Registry.notify(@path, new_value, observe: @sequence) if changed
      changed
    end

    # Ends the observation of this topic (RFC 7641 §4.2): each observer receives one 4.04
    # notification with no Observe option, and every entry is removed. Later reads are
    # answered 4.04 by the router, which removes the route along with the topic.
    #
    # @return [void]
    def delete
      @mutex.synchronize do
        @deleted = true
        @value = nil
      end

      Observer::Registry.notify(@path, nil, code: '4.04 Not Found', observe: nil)
    end

    # Serves one request against this topic. Returns an Outbound response: 2.05 with the
    # current representation (plus an Observe option when a registration is confirmed), a
    # registration refusal as a plain 2.05 without an Observe option, and 4.04 once the
    # topic is deleted.
    #
    # @param request [Takagi::Message::Inbound]
    # @return [Takagi::Message::Outbound]
    def handle_request(request)
      return not_found(request) if deleted?

      case observe_value(request)
      when 0 then handle_register(request)
      when 1 then handle_deregister(request)
      else respond(request, include_observe: false)
      end
    end

    private

    def handle_register(request)
      if refused?(request.transport)
        respond(request, include_observe: false)
      else
        register_observer(request)
        respond(request, include_observe: true)
      end
    end

    def handle_deregister(request)
      host, port = source_endpoint(request)
      Observer::Registry.remove(@path, endpoint: "#{host}:#{port}", token: token_of(request))
      respond(request, include_observe: false)
    end

    # Whether this binding registers observers over the requesting transport: over a
    # reliable transport the binding declines subscription confirmation, so the server MAY
    # answer the GET normally without an Observe option (RFC 7641 §4.1), which is exactly
    # what a refused registration looks like on the wire.
    def refused?(transport)
      binding = PubSub::TransportRegistry.resolve(:coap_observe)
      binding.for_transport(transport).capabilities[:subscription_confirmed] == false
    rescue PubSub::TransportRegistry::TransportNotFoundError
      true
    end

    def register_observer(request)
      host, port = source_endpoint(request)
      Observer::Registry.subscribe(
        @path,
        endpoint: "#{host}:#{port}",
        address: host,
        port: port,
        token: token_of(request),
        kind: :inbound,
        transport: request.transport,
        content_format: @content_format,
        created_at: Time.now
      )
    end

    def respond(request, include_observe:)
      options = { CoAP::Registries::Option::CONTENT_FORMAT => [@content_format] }
      options[CoAP::Registries::Option::OBSERVE] = [sequence] if include_observe
      request.to_response('2.05 Content', current_value, options: options)
    end

    def not_found(request)
      request.to_response('4.04 Not Found', { error: 'not found' })
    end

    def source_endpoint(request)
      endpoint = request.source_endpoint
      return endpoint if endpoint.is_a?(Array) && endpoint.size == 2

      ['localhost', 5683]
    end

    def token_of(request)
      (request.token || '').to_s.b
    end

    def observe_value(request)
      raw = Array(request.options && request.options[CoAP::Registries::Option::OBSERVE]).first
      return nil unless raw

      raw.to_s.b.bytes.reduce(0) { |acc, byte| (acc << 8) | byte }
    end
  end
end
