# frozen_string_literal: true

module Takagi
  module PubSub
    # One publish/subscribe vocabulary, declared once (design D7).
    #
    # Every surface that offers publish/subscribe operations resolves a requested name through
    # this table, so `notify` means publish, `observe` means subscribe, `cancel` means
    # unsubscribe — everywhere. A name outside the vocabulary is refused loudly rather than
    # silently ignored.
    class ReactorInteraction
      # The verbs every publish/subscribe surface offers.
      VERBS = %i[publish subscribe unsubscribe read delete].freeze

      # The alias spellings that denote each verb. A spelling means the same operation on
      # every surface that resolves through the table.
      ALIASES = {
        publish: %i[publish notify emit].freeze,
        subscribe: %i[subscribe observe on consumer].freeze,
        unsubscribe: %i[unsubscribe cancel].freeze,
        read: %i[read].freeze,
        delete: %i[delete].freeze
      }.freeze

      # spelling => verb, the lookup the surfaces use.
      SPELLINGS = ALIASES.each_with_object({}) do |(verb, spellings), table|
        spellings.each { |spelling| table[spelling] = verb }
      end.freeze

      # Raised when a publish/subscribe operation is requested under a name the vocabulary
      # does not contain. The message carries the unknown name.
      class UnknownNameError < StandardError; end

      class << self
        # The verb a spelling denotes, or a refused request naming the unknown spelling.
        #
        # @param name [Symbol, String] a requested operation name
        # @return [Symbol] one of {VERBS}
        # @raise [UnknownNameError] when the name is not part of the vocabulary
        def resolve(name)
          verb = SPELLINGS[name.to_sym]
          return verb if verb

          raise UnknownNameError,
                "unknown publish/subscribe verb #{name.inspect}; known names: #{SPELLINGS.keys.join(', ')}"
        end

        # Whether a name is part of the vocabulary.
        #
        # @param name [Symbol, String]
        # @return [Boolean]
        def verb?(name)
          SPELLINGS.key?(name.to_sym)
        end

        # Every spelling that denotes a verb.
        #
        # @param verb [Symbol] one of {VERBS}
        # @return [Array<Symbol>]
        def spellings_for(verb)
          ALIASES.fetch(verb) do
            raise UnknownNameError, "no such publish/subscribe verb: #{verb.inspect}"
          end
        end

        # The full spelling => verb table.
        #
        # @return [Hash{Symbol => Symbol}]
        def spellings
          SPELLINGS
        end
      end
    end
  end
end
