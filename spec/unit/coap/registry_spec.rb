# frozen_string_literal: true

RSpec.describe Takagi::CoAP::Registries::Base do
  # Create a test registry
  class TestRegistry < Takagi::CoAP::Registries::Base
    register(1, 'First Value', :first, rfc: 'RFC 0001')
    register(2, 'Second Value', :second)
    register(3, 'Third Value', nil, rfc: 'RFC 0003') # No symbol
  end

  after(:each) do
    # Clean up any additional registrations
    TestRegistry.instance_variable_set(:@registry, {
                                          1 => { name: 'First Value', symbol: :first, rfc: 'RFC 0001' },
                                          2 => { name: 'Second Value', symbol: :second, rfc: nil },
                                          3 => { name: 'Third Value', symbol: nil, rfc: 'RFC 0003' }
                                        })
    TestRegistry.instance_variable_set(:@reverse_registry, {
                                          'First Value' => 1,
                                          :first => 1,
                                          'Second Value' => 2,
                                          :second => 2,
                                          'Third Value' => 3
                                        })
  end

  describe '.register' do
    it 'registers a constant with symbol' do
      expect(TestRegistry::FIRST).to eq(1)
      expect(TestRegistry::SECOND).to eq(2)
    end

    it 'stores name mapping' do
      expect(TestRegistry.name_for(1)).to eq('First Value')
      expect(TestRegistry.name_for(2)).to eq('Second Value')
    end

    it 'stores RFC reference' do
      expect(TestRegistry.rfc_for(1)).to eq('RFC 0001')
      expect(TestRegistry.rfc_for(3)).to eq('RFC 0003')
    end

    it 'handles registration without symbol' do
      expect(TestRegistry.name_for(3)).to eq('Third Value')
    end

    it 'allows plugins to add new constants' do
      TestRegistry.register(99, 'Plugin Value', :plugin)
      expect(TestRegistry::PLUGIN).to eq(99)
      expect(TestRegistry.name_for(99)).to eq('Plugin Value')
    end
  end

  describe '.name_for' do
    it 'returns name for registered value' do
      expect(TestRegistry.name_for(1)).to eq('First Value')
    end

    it 'returns nil for unregistered value' do
      expect(TestRegistry.name_for(999)).to be_nil
    end
  end

  describe '.value_for' do
    it 'returns value for name' do
      expect(TestRegistry.value_for('First Value')).to eq(1)
    end

    it 'returns value for symbol' do
      expect(TestRegistry.value_for(:first)).to eq(1)
      expect(TestRegistry.value_for(:second)).to eq(2)
    end

    it 'returns nil for unregistered key' do
      expect(TestRegistry.value_for('Unknown')).to be_nil
      expect(TestRegistry.value_for(:unknown)).to be_nil
    end
  end

  describe '.registered?' do
    it 'returns true for registered values' do
      expect(TestRegistry.registered?(1)).to be true
      expect(TestRegistry.registered?(2)).to be true
    end

    it 'returns false for unregistered values' do
      expect(TestRegistry.registered?(999)).to be false
    end
  end

  describe '.all' do
    it 'returns all registered values and names' do
      all = TestRegistry.all
      expect(all).to include(1 => 'First Value', 2 => 'Second Value', 3 => 'Third Value')
    end
  end

  describe '.values' do
    it 'returns all registered values' do
      expect(TestRegistry.values).to contain_exactly(1, 2, 3)
    end
  end

  describe '.metadata_for' do
    it 'returns full metadata hash' do
      metadata = TestRegistry.metadata_for(1)
      expect(metadata).to eq({
                               name: 'First Value',
                               symbol: :first,
                               rfc: 'RFC 0001'
                             })
    end

    it 'returns nil for unregistered value' do
      expect(TestRegistry.metadata_for(999)).to be_nil
    end
  end
end
