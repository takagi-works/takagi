# frozen_string_literal: true

RSpec.describe Takagi::PubSub::ReactorInteraction do
  describe '.resolve' do
    it 'resolves every alias spelling of a verb to that verb' do
      described_class::ALIASES.each do |verb, spellings|
        spellings.each do |spelling|
          expect(described_class.resolve(spelling)).to eq(verb)
          expect(described_class.resolve(spelling.to_s)).to eq(verb)
        end
      end
    end

    it 'refuses an unknown name, naming it' do
      expect { described_class.resolve(:teleport) }
        .to raise_error(described_class::UnknownNameError, /teleport/)
    end

    it 'exposes every verb of the vocabulary' do
      expect(described_class::VERBS).to contain_exactly(
        :publish, :subscribe, :unsubscribe, :read, :delete
      )
    end
  end

  describe '.spellings_for' do
    it 'returns the alias spellings of a verb, including the verb itself' do
      expect(described_class.spellings_for(:subscribe)).to contain_exactly(
        :subscribe, :observe, :on, :consumer
      )
    end
  end
end