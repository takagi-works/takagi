# frozen_string_literal: true

require_relative 'hooks'
require_relative 'serialization'

module Takagi
  # Builds CoAP responses from middleware results
  class ResponseBuilder
    DEFAULT_RESPONSE_CODE = CoAP::Registries::Response::CONTENT

    # Builds a response from the middleware result
    #
    # @param inbound_request [Takagi::Message::Inbound] The original request
    # @param result [Takagi::Message::Outbound, Hash, Object] The middleware result
    # @param logger [Logger, nil] Optional logger for debugging
    # @return [Takagi::Message::Outbound] The response message
    def self.build(inbound_request, result, logger: nil)
      Takagi::Hooks.emit(:before_response_build, inbound: inbound_request, result: result)

      case result
      when Takagi::Message::Outbound
        response = result
      when Hash, String
        logger&.debug("Returned #{result.class} as response")
        response = respond(inbound_request, result, logger: logger)
      else
        logger&.warn("Middleware returned non-Hash: #{result.inspect}")
        response = inbound_request.to_response('5.00 Internal Server Error', { error: 'Internal Server Error' })
      end

      Takagi::Hooks.emit(:after_response_build, inbound: inbound_request, response: response, result: result)
      response
    end

    # Build a CoAP response with content-format negotiation.
    #
    # @param inbound_request [Takagi::Message::Inbound] The original request
    # @param payload [Object] The payload to serialize
    # @param code [Integer, String, Symbol] CoAP response code (default 2.05 Content)
    # @param formats [Array<Integer, Symbol, String>, nil] Allowed content-format codes
    # @param force [Integer, Symbol, String, nil] Force a specific content-format code
    # @param options [Hash] Additional CoAP options
    # @param logger [Logger, nil] Logger for debug output
    # @return [Takagi::Message::Outbound]
    def self.respond(inbound_request, payload, code: DEFAULT_RESPONSE_CODE, formats: nil, force: nil, options: {}, logger: nil)
      requested_formats = formats || inbound_request&.content_format
      allowed_formats = normalize_formats(requested_formats)
      forced_format = normalize_format(force)
      accept_format = normalize_format(extract_accept(inbound_request))

      selected_format = select_format(allowed_formats, accept_format, forced_format, logger)

      case selected_format
      when :not_acceptable
        return inbound_request.to_response(CoAP::Registries::Response::NOT_ACCEPTABLE, { error: 'Not Acceptable' })
      when :unsupported
        return inbound_request.to_response(CoAP::Registries::Response::UNSUPPORTED_CONTENT_FORMAT, { error: 'Unsupported Content-Format' })
      end

      content_options = (options || {}).dup
      if selected_format
        content_options[CoAP::Registries::Option::CONTENT_FORMAT] ||= [selected_format]
      end

      inbound_request.to_response(code, payload, options: content_options)
    end

    class << self
      private

      def normalize_formats(formats)
        list = Array(formats || default_format)
        normalized = list.map { |fmt| normalize_format(fmt) }.compact
        normalized.empty? ? [default_format] : normalized
      end

      def select_format(allowed_formats, accept_format, forced_format, logger)
        if forced_format
          return :unsupported unless Serialization::Registry.supports?(forced_format)

          return forced_format
        end

        if accept_format
          if Serialization::Registry.supports?(accept_format) && allowed_formats.include?(accept_format)
            return accept_format
          end

          logger&.debug("Accept format #{accept_format.inspect} not supported")
          return :not_acceptable
        end

        allowed_formats.find { |fmt| Serialization::Registry.supports?(fmt) } || default_format
      end

      def normalize_format(format)
        return nil if format.nil?
        return format if format.is_a?(Integer)
        return format.content_format_code if format.respond_to?(:content_format_code)

        if format.is_a?(Array)
          return normalize_format(format.first)
        end

        if format.is_a?(Symbol) || format.is_a?(String)
          registry_value = CoAP::Registries::ContentFormat.value_for(format) ||
                           CoAP::Registries::ContentFormat.value_for(format.to_s.downcase.to_sym)
          return registry_value if registry_value
        end

        if format.is_a?(String)
          decoded = decode_content_format_bytes(format)
          return decoded if decoded
        end

        nil
      end

      def decode_content_format_bytes(value)
        bytes = value.b.bytes
        return nil if bytes.empty? || bytes.length > 2

        bytes.reduce(0) { |acc, byte| (acc << 8) | byte }
      end

      def extract_accept(inbound_request)
        return unless inbound_request.respond_to?(:accept)

        inbound_request.accept
      end

      def default_format
        if defined?(Takagi::Router::DEFAULT_CONTENT_FORMAT)
          Takagi::Router::DEFAULT_CONTENT_FORMAT
        else
          CoAP::Registries::ContentFormat::JSON
        end
      end
    end
  end
end
