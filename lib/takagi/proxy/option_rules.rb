# frozen_string_literal: true

module Takagi
  class Proxy
    # The option classification a CoAP proxy needs (RFC 7252 5.4.1/5.4.6 and 5.7.1).
    #
    # The two questions are deliberately different. What a proxy may FORWARD turns on
    # Unsafe/Safe-to-Forward: an option the registry does not know and whose class is Unsafe is one
    # a proxy must not pass on. What a NON-proxying endpoint must refuse turns on Critical/Elective,
    # which is why the LOCAL path asks the second question and the forwarding path never does -
    # option 66 is elective and unsafe, option 69 is critical and safe, and a proxy that confused
    # the two would both refuse option 69 and forward option 66.
    class OptionRules
      # @param options [Hash, nil] CoAP options { option_number => value }
      # @return [Array<Integer>] the unrecognized Unsafe options
      def self.unrecognized_unsafe(options)
        unrecognized(options).select { |number| CoAP::Registries::Option.unsafe?(number) }
      end

      # @param options [Hash, nil] CoAP options { option_number => value }
      # @return [Array<Integer>] the unrecognized Critical options
      def self.unrecognized_critical(options)
        unrecognized(options).select { |number| CoAP::Registries::Option.critical?(number) }
      end

      # The options the registry does not name.
      #
      # @param options [Hash, nil] CoAP options { option_number => value }
      # @return [Array<Integer>]
      def self.unrecognized(options)
        (options || {}).keys.reject { |number| CoAP::Registries::Option.name_for(number) }
      end
    end
  end
end
