# frozen_string_literal: true

require 'spec_helper'
require 'timeout'

RSpec.describe Takagi::Bus::CoAPBridge do
  let(:app) do
    Class.new do
      attr_reader :observables

      def initialize
        @observables = {}
      end

      def observable(path, &block)
        @observables[path] = block
      end
    end.new
  end

  before do
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

  describe '.register_observable_resource' do
    it 'creates the observable path and returns true' do
      result = described_class.register_observable_resource('sensor.temp.room1', app)

      expect(result).to be true
      expect(described_class.registered?('sensor.temp.room1')).to be true
      expect(app.observables.keys).to eq(['/events/sensor/temp/room1'])
    end

    it 'returns false and keeps the first registration on a repeat call' do
      described_class.register_observable_resource('sensor.temp.room1', app)
      second = described_class.register_observable_resource('sensor.temp.room1', app)

      expect(second).to be false
      expect(described_class.registered_count).to eq(1)
    end

    it 'serves a constant descriptor rather than bus state' do
      described_class.register_observable_resource('sensor.temp.room1', app)
      representation = app.observables.fetch('/events/sensor/temp/room1').call(nil)

      expect(representation).to include(address: 'sensor.temp.room1', status: 'observable')
      expect(representation[:timestamp]).to be_a(Integer)
    end

    it 'still serves the descriptor after a publish, so it reads no bus state' do
      described_class.register_observable_resource('sensor.temp.room1', app)
      Takagi.bus.publish('sensor.temp.room1', { value: 25.5 })

      representation = app.observables.fetch('/events/sensor/temp/room1').call(nil)

      expect(representation).to include(address: 'sensor.temp.room1', status: 'observable')
      expect(representation[:body]).to be_nil
    end

    it 'returns false and unregisters when the app rejects the resource' do
      allow(app).to receive(:observable).and_raise(StandardError, 'no observable support')

      result = described_class.register_observable_resource('sensor.temp.room1', app)

      expect(result).to be false
      expect(described_class.registered?('sensor.temp.room1')).to be false
    end
  end

  describe '.registered?' do
    it 'returns false for unregistered address' do
      expect(described_class.registered?('sensor.temp.room1')).to be false
    end

    it 'returns true for registered address' do
      described_class.register_observable_resource('sensor.temp.room1', app)

      expect(described_class.registered?('sensor.temp.room1')).to be true
    end
  end

  describe '.registered_addresses' do
    it 'returns empty array initially' do
      expect(described_class.registered_addresses).to eq([])
    end

    it 'returns all registered addresses' do
      described_class.register_observable_resource('sensor.temp.room1', app)
      described_class.register_observable_resource('alert.fire.detected', app)

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
      described_class.register_observable_resource('sensor.temp.room1', app)
      described_class.register_observable_resource('alert.fire.detected', app)

      expect(described_class.registered_count).to eq(2)
    end
  end

  describe '.unregister' do
    it 'removes registered address' do
      described_class.register_observable_resource('sensor.temp.room1', app)

      expect(described_class.registered?('sensor.temp.room1')).to be true
      described_class.unregister('sensor.temp.room1')
      expect(described_class.registered?('sensor.temp.room1')).to be false
    end

    it 'returns true if was registered' do
      described_class.register_observable_resource('sensor.temp.room1', app)

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
      described_class.register_observable_resource('sensor.temp.room1', app)
      described_class.register_observable_resource('alert.fire.detected', app)

      expect(described_class.registered_count).to eq(2)

      described_class.clear
      expect(described_class.registered_count).to eq(0)
    end
  end

  describe 'thread safety' do
    it 'handles concurrent registrations of distinct addresses' do
      threads = 10.times.map do |i|
        Thread.new { described_class.register_observable_resource("sensor.temp.room#{i}", app) }
      end

      Timeout.timeout(5) { threads.each(&:join) }

      expect(described_class.registered_count).to eq(10)
    end

    it 'prevents duplicate registrations' do
      threads = 10.times.map do
        Thread.new { described_class.register_observable_resource('sensor.temp.room1', app) }
      end

      Timeout.timeout(5) { threads.each(&:join) }

      expect(described_class.registered_count).to eq(1)
    end

    it 'serves concurrent reads while writes are in flight without error' do
      errors = Queue.new

      writer = Thread.new do
        50.times { |i| described_class.register_observable_resource("sensor.#{i}", app) }
      rescue StandardError => e
        errors << e
      end

      readers = 5.times.map do
        Thread.new do
          50.times do
            described_class.registered_addresses
            described_class.registered_count
          rescue StandardError => e
            errors << e
          end
        end
      end

      Timeout.timeout(5) { ([writer] + readers).each(&:join) }

      expect(errors).to be_empty
    end
  end

  describe '.publish_to_observers' do
    it 'notifies ObserveRegistry with the built payload' do
      message = Takagi::Bus::Message.new('sensor.temp.room1', { value: 25.5 })

      expect(Takagi::ObserveRegistry).to receive(:notify).with(
        '/events/sensor/temp/room1',
        hash_including(address: 'sensor.temp.room1', body: { value: 25.5 })
      )

      described_class.publish_to_observers('sensor.temp.room1', message)
    end

    it 'logs and swallows a notification failure without touching bus state' do
      message = Takagi::Bus::Message.new('sensor.temp.room1', { value: 25.5 })
      allow(Takagi::ObserveRegistry).to receive(:notify).and_raise(StandardError, 'registry down')
      expect(Takagi.logger).to receive(:error).with(/Error publishing to observers/)

      expect do
        described_class.publish_to_observers('sensor.temp.room1', message)
      end.not_to raise_error
    end
  end

  describe '.subscribe_remote' do
    it 'raises NotImplementedError until remote observe is implemented' do
      expect do
        described_class.subscribe_remote('sensor.temp.buildingA', 'coap://building-a:5683') { }
      end.to raise_error(NotImplementedError, /not implemented/)
    end
  end

  describe 'local bus isolation' do
    let(:bus) { Takagi::Bus.new }

    after { bus.shutdown }

    it 'delivers a formerly-distributed publish locally and registers no observable' do
      received = nil
      allow(described_class).to receive(:register_observable_resource).and_call_original

      bus.consumer('sensor.temp.room1') { |msg| received = msg.body }

      bus.publish('sensor.temp.room1', { value: 25.5 })

      expect(received).to eq({ value: 25.5 })
      expect(described_class).not_to have_received(:register_observable_resource)
      expect(described_class.registered_count).to eq(0)
    end
  end
end
