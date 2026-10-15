# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Takagi::EventBus::CoAPBridge do
  # Clean up registered resources before each test
  before(:each) do
    described_class.clear
  end

  describe '.address_to_path' do
    it 'converts event address to CoAP path' do
      path = described_class.address_to_path('sensor.temperature.room1')
      expect(path).to eq('/events/sensor/temperature/room1')
    end

    it 'handles simple addresses' do
      path = described_class.address_to_path('alert.fire')
      expect(path).to eq('/events/alert/fire')
    end

    it 'handles complex addresses' do
      path = described_class.address_to_path('cluster.node.status.health')
      expect(path).to eq('/events/cluster/node/status/health')
    end
  end

  describe '.path_to_address' do
    it 'converts CoAP path to event address' do
      address = described_class.path_to_address('/events/sensor/temperature/room1')
      expect(address).to eq('sensor.temperature.room1')
    end

    it 'handles simple paths' do
      address = described_class.path_to_address('/events/alert/fire')
      expect(address).to eq('alert.fire')
    end

    it 'handles complex paths' do
      address = described_class.path_to_address('/events/cluster/node/status/health')
      expect(address).to eq('cluster.node.status.health')
    end
  end

  describe '.address_to_path and .path_to_address' do
    it 'are inverses of each other' do
      original = 'sensor.temperature.room1'
      path = described_class.address_to_path(original)
      address = described_class.path_to_address(path)

      expect(address).to eq(original)
    end
  end

  describe '.registered?' do
    it 'returns false for unregistered address' do
      expect(described_class.registered?('sensor.temp.room1')).to be false
    end

    it 'returns true for registered address' do
      described_class.instance_variable_get(:@mutex).synchronize do
        described_class.instance_variable_get(:@registered_resources) << 'sensor.temp.room1'
      end

      expect(described_class.registered?('sensor.temp.room1')).to be true
    end
  end

  describe '.registered_addresses' do
    it 'returns empty array initially' do
      expect(described_class.registered_addresses).to eq([])
    end

    it 'returns all registered addresses' do
      mutex = described_class.instance_variable_get(:@mutex)
      resources = described_class.instance_variable_get(:@registered_resources)

      mutex.synchronize do
        resources << 'sensor.temp.room1'
        resources << 'alert.fire.detected'
      end

      expect(described_class.registered_addresses).to match_array([
        'sensor.temp.room1',
        'alert.fire.detected'
      ])
    end
  end

  describe '.registered_count' do
    it 'returns 0 initially' do
      expect(described_class.registered_count).to eq(0)
    end

    it 'returns count of registered resources' do
      mutex = described_class.instance_variable_get(:@mutex)
      resources = described_class.instance_variable_get(:@registered_resources)

      mutex.synchronize do
        resources << 'sensor.temp.room1'
        resources << 'alert.fire.detected'
      end

      expect(described_class.registered_count).to eq(2)
    end
  end

  describe '.unregister' do
    it 'removes registered address' do
      mutex = described_class.instance_variable_get(:@mutex)
      resources = described_class.instance_variable_get(:@registered_resources)

      mutex.synchronize do
        resources << 'sensor.temp.room1'
      end

      expect(described_class.registered?('sensor.temp.room1')).to be true
      described_class.unregister('sensor.temp.room1')
      expect(described_class.registered?('sensor.temp.room1')).to be false
    end

    it 'returns true if was registered' do
      mutex = described_class.instance_variable_get(:@mutex)
      resources = described_class.instance_variable_get(:@registered_resources)

      mutex.synchronize do
        resources << 'sensor.temp.room1'
      end

      result = described_class.unregister('sensor.temp.room1')
      expect(result).to be true
    end

    it 'returns false if was not registered' do
      result = described_class.unregister('not.registered')
      expect(result).to be_falsy
    end
  end

  describe '.clear' do
    it 'removes all registrations' do
      mutex = described_class.instance_variable_get(:@mutex)
      resources = described_class.instance_variable_get(:@registered_resources)

      mutex.synchronize do
        resources << 'sensor.temp.room1'
        resources << 'alert.fire.detected'
      end

      expect(described_class.registered_count).to eq(2)

      described_class.clear
      expect(described_class.registered_count).to eq(0)
    end
  end

  describe 'thread safety' do
    it 'handles concurrent registrations' do
      # Mock the EventBus.distributed? check
      allow(Takagi::EventBus).to receive(:distributed?).and_return(false)

      threads = 10.times.map do |i|
        Thread.new do
          described_class.instance_variable_get(:@mutex).synchronize do
            described_class.instance_variable_get(:@registered_resources) << "sensor.temp.room#{i}"
          end
        end
      end

      threads.each(&:join)

      expect(described_class.registered_count).to eq(10)
    end

    it 'prevents duplicate registrations' do
      # Mock the EventBus.distributed? check
      allow(Takagi::EventBus).to receive(:distributed?).and_return(false)

      threads = 10.times.map do
        Thread.new do
          described_class.instance_variable_get(:@mutex).synchronize do
            described_class.instance_variable_get(:@registered_resources) << 'sensor.temp.room1'
          end
        end
      end

      threads.each(&:join)

      # Set should prevent duplicates
      expect(described_class.registered_count).to eq(1)
    end

    it 'handles concurrent reads and writes' do
      stop = false
      errors = []

      # Writer thread
      writer = Thread.new do
        100.times do |i|
          begin
            described_class.instance_variable_get(:@mutex).synchronize do
              described_class.instance_variable_get(:@registered_resources) << "sensor.#{i}"
            end
          rescue => e
            errors << e
          end
          break if stop
        end
      end

      # Reader threads
      readers = 5.times.map do
        Thread.new do
          100.times do
            begin
              described_class.registered_addresses
              described_class.registered_count
            rescue => e
              errors << e
            end
            break if stop
          end
        end
      end

      sleep 0.2
      stop = true

      writer.join
      readers.each(&:join)

      expect(errors).to be_empty
    end
  end

  describe '.subscribe_remote' do
    it 'raises NotImplementedError until remote observe is implemented' do
      expect do
        described_class.subscribe_remote('sensor.temp.buildingA', 'coap://building-a:5683') { }
      end.to raise_error(NotImplementedError, /not implemented/)
    end
  end
end