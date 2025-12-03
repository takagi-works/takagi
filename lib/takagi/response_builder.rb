# frozen_string_literal: true

require_relative 'hooks'

module Takagi
  # Builds CoAP responses from middleware results
  class ResponseBuilder
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
      when Hash
        logger&.debug("Returned #{result} as response")
        response = inbound_request.to_response('2.05 Content', result)
      else
        logger&.warn("Middleware returned non-Hash: #{result.inspect}")
        response = inbound_request.to_response('5.00 Internal Server Error', { error: 'Internal Server Error' })
      end

      Takagi::Hooks.emit(:after_response_build, inbound: inbound_request, response: response, result: result)
      response
    end
  end
end
