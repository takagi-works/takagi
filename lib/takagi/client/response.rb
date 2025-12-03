# frozen_string_literal: true

module Takagi
  class Client
    # Wrapper for CoAP responses providing convenient access to response data
    # and status checking methods.
    #
    # Uses the CoAP registry system for all code checking and naming.
    #
    # @example Basic usage
    #   client.get('/temperature') do |response|
    #     if response.success?
    #       puts "Temperature: #{response.payload}"
    #     else
    #       puts "Error: #{response.code_name}"
    #     end
    #   end
    #
    # @example Checking specific codes
    #   response.ok?          # 2.05 Content
    #   response.created?     # 2.01 Created
    #   response.not_found?   # 4.04 Not Found
    #   response.bad_request? # 4.00 Bad Request
    class Response
      attr_reader :raw_data, :inbound, :code, :payload, :options, :token

      # Creates a new Response wrapper
      # @param raw_data [String] Raw binary response data
      def initialize(raw_data)
        @raw_data = raw_data
        @inbound = Takagi::Message::Inbound.new(raw_data)
        @code = @inbound.code
        @payload = @inbound.payload
        @options = @inbound.options
        @token = @inbound.token
      end

      # Get the human-readable code name using CoAP registry
      # @return [String] Code name (e.g., "2.05 Content", "4.04 Not Found")
      def code_name
        CoAP::CodeHelpers.to_string(@code)
      end

      # Get the numeric code class (2 = Success, 4 = Client Error, 5 = Server Error)
      # @return [Integer] Code class
      def code_class
        CoAP::Registries::Response.class_for(@code)
      end

      # Check if response is successful (2.xx)
      # @return [Boolean]
      def success?
        CoAP::Registries::Response.success?(@code)
      end

      # Check if response is a client error (4.xx)
      # @return [Boolean]
      def client_error?
        CoAP::Registries::Response.client_error?(@code)
      end

      # Check if response is a server error (5.xx)
      # @return [Boolean]
      def server_error?
        CoAP::Registries::Response.server_error?(@code)
      end

      # Check if response has an error (4.xx or 5.xx)
      # @return [Boolean]
      def error?
        CoAP::Registries::Response.error?(@code)
      end

      # Common 2.xx success codes (using registry)
      def created?
        @code == CoAP::Registries::Response::CREATED
      end

      def deleted?
        @code == CoAP::Registries::Response::DELETED
      end

      def valid?
        @code == CoAP::Registries::Response::VALID
      end

      def changed?
        @code == CoAP::Registries::Response::CHANGED
      end

      def content?
        @code == CoAP::Registries::Response::CONTENT
      end
      alias ok? content?

      # Common 4.xx client error codes (using registry)
      def bad_request?
        @code == CoAP::Registries::Response::BAD_REQUEST
      end

      def unauthorized?
        @code == CoAP::Registries::Response::UNAUTHORIZED
      end

      def bad_option?
        @code == CoAP::Registries::Response::BAD_OPTION
      end

      def forbidden?
        @code == CoAP::Registries::Response::FORBIDDEN
      end

      def not_found?
        @code == CoAP::Registries::Response::NOT_FOUND
      end

      def method_not_allowed?
        @code == CoAP::Registries::Response::METHOD_NOT_ALLOWED
      end

      def not_acceptable?
        @code == CoAP::Registries::Response::NOT_ACCEPTABLE
      end

      def precondition_failed?
        @code == CoAP::Registries::Response::PRECONDITION_FAILED
      end

      def request_entity_too_large?
        @code == CoAP::Registries::Response::REQUEST_ENTITY_TOO_LARGE
      end

      def unsupported_content_format?
        @code == CoAP::Registries::Response::UNSUPPORTED_CONTENT_FORMAT
      end

      # Common 5.xx server error codes (using registry)
      def internal_server_error?
        @code == CoAP::Registries::Response::INTERNAL_SERVER_ERROR
      end

      def not_implemented?
        @code == CoAP::Registries::Response::NOT_IMPLEMENTED
      end

      def bad_gateway?
        @code == CoAP::Registries::Response::BAD_GATEWAY
      end

      def service_unavailable?
        @code == CoAP::Registries::Response::SERVICE_UNAVAILABLE
      end

      def gateway_timeout?
        @code == CoAP::Registries::Response::GATEWAY_TIMEOUT
      end

      def proxying_not_supported?
        @code == CoAP::Registries::Response::PROXYING_NOT_SUPPORTED
      end

      # Deserialize payload using content-format
      #
      # Automatically deserializes payload based on Content-Format option.
      # Falls back to JSON for unknown formats or if deserialization fails.
      #
      # @return [Object, nil] Deserialized data or nil
      #
      # @example JSON response
      #   response.data  # => { "temp" => 25 }
      #
      # @example CBOR response
      #   response.data  # => { "temp" => 25 }
      #
      # @example Text response
      #   response.data  # => "Hello World"
      def data
        return nil unless @payload

        format = content_format || CoAP::Registries::ContentFormat::JSON

        Serialization::Registry.decode(@payload, format)
      rescue Serialization::UnknownFormatError
        # Unknown format - try JSON as fallback
        Serialization::Registry.decode(@payload, CoAP::Registries::ContentFormat::JSON)
      rescue Serialization::DecodeError
        # Decoding failed - return raw payload
        @payload
      end

      # Check if response has JSON content-format
      # @return [Boolean]
      def json?
        content_format == CoAP::Registries::ContentFormat::JSON
      end

      # Get content-format option value
      # @return [Integer, nil] Content-format code
      def content_format
        return nil unless @options

        value = @options[CoAP::Registries::Option::CONTENT_FORMAT]
        return nil if value.nil?

        # Handle both array and non-array values
        value = value.first if value.is_a?(Array)

        # Convert to integer (content-format is numeric)
        value.is_a?(String) ? decode_integer_value(value) : value
      end

      # String representation for debugging
      # @return [String]
      def to_s
        "#<Takagi::Client::Response code=#{code_name} payload_size=#{@payload&.bytesize || 0}>"
      end

      # Detailed inspection
      # @return [String]
      def inspect
        "#<Takagi::Client::Response code=#{code_name} " \
          "success=#{success?} " \
          "payload=#{@payload&.byteslice(0, 50)&.inspect}#{@payload && @payload.bytesize > 50 ? '...' : ''}>"
      end

      private

      # Decode a binary string to an integer
      def decode_integer_value(bytes)
        return nil if bytes.nil? || bytes.empty?

        bytes.bytes.reduce(0) { |acc, byte| (acc << 8) | byte }
      end
    end
  end
end
