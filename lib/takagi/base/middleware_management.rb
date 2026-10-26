# frozen_string_literal: true

module Takagi
  class Base < Router
    # Manages middleware stack configuration and request processing.
    #
    # Extracted from Base class to follow Single Responsibility Principle.
    # Handles middleware registration and stack initialization.
    module MiddlewareManagement
      # Processes a request through the middleware stack
      #
      # @param request [Message::Inbound] Incoming CoAP request
      # @return [Message::Outbound] Response after middleware processing
      def call(request)
        middleware_stack.call(request)
      end

      # Returns the middleware stack instance
      #
      # A Base service resolves through the process-global router, so it runs the process-wide
      # stack. A service with isolated routes (an Application's CompositeRouter) builds its own.
      #
      # @return [MiddlewareStack] The middleware stack instance
      def middleware_stack
        @middleware_stack ||= Takagi::MiddlewareStack.instance
      end

      # Adds a middleware to the stack
      #
      # @param middleware [Object] Middleware instance responding to #call
      #
      # @example
      #   use CustomMiddleware.new
      #   use Takagi::Middleware::Caching.new(ttl: 300)
      def use(middleware)
        middleware_stack.use(middleware)
      end
    end
  end
end
