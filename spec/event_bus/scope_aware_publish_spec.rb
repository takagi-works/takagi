# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Takagi::EventBus, 'scope-aware publishing' do
  let(:event_bus) { described_class }

  after(:all) do
    # Only shutdown once at the end of all tests
    described_class.shutdown
  end

  describe 'Message scope' do
    it 'defaults to :local if not specified' do
      message = event_bus.publish('test.event', { data: 'test' })
      expect(message.scope).to eq(:local)
    end

    it 'accepts explicit :local scope' do
      message = event_bus.publish('test.event', { data: 'test' }, scope: :local)
      expect(message.scope).to eq(:local)
    end

    it 'accepts :cluster scope' do
      message = event_bus.publish('test.event', { data: 'test' }, scope: :cluster)
      expect(message.scope).to eq(:cluster)
    end

    it 'accepts :global scope' do
      message = event_bus.publish('test.event', { data: 'test' }, scope: :global)
      expect(message.scope).to eq(:global)
    end

    it 'normalizes string scope to symbol' do
      message = event_bus.publish('test.event', { data: 'test' }, scope: 'cluster')
      expect(message.scope).to eq(:cluster)
    end

    it 'normalizes invalid scope to :local' do
      message = event_bus.publish('test.event', { data: 'test' }, scope: :invalid)
      expect(message.scope).to eq(:local)
    end

    it 'includes scope in message attributes' do
      message = event_bus.publish('test.event', { data: 'test' }, scope: :global)
      expect(message).to respond_to(:scope)
      expect(message.scope).to eq(:global)
    end
  end

  describe 'Local scope delivery' do
    it 'delivers local messages to consumers' do
      received = nil
      event_bus.consumer('local.event') do |msg|
        received = msg
      end

      event_bus.publish('local.event', { data: 'test' }, scope: :local)
      sleep 0.1  # Allow async delivery

      expect(received).not_to be_nil
      expect(received.scope).to eq(:local)
      expect(received.body).to eq({ data: 'test' })
    end

    it 'delivers default scope messages to consumers' do
      received = nil
      event_bus.consumer('default.event') do |msg|
        received = msg
      end

      event_bus.publish('default.event', { data: 'test' })
      sleep 0.1

      expect(received).not_to be_nil
      expect(received.scope).to eq(:local)
    end
  end

  describe 'Cluster scope delivery' do
    it 'delivers cluster messages locally' do
      received = nil
      event_bus.consumer('cluster.event') do |msg|
        received = msg
      end

      event_bus.publish('cluster.event', { data: 'test' }, scope: :cluster)
      sleep 0.1

      expect(received).not_to be_nil
      expect(received.scope).to eq(:cluster)
    end

    it 'warns that cluster distribution is not implemented' do
      expect(Takagi.logger).to receive(:warn).with(/Cluster distribution is not implemented/)

      event_bus.publish('cluster.event', { data: 'test' }, scope: :cluster)
    end
  end

  describe 'Global scope delivery' do
    it 'delivers global messages locally' do
      received = nil
      event_bus.consumer('global.event') do |msg|
        received = msg
      end

      event_bus.publish('global.event', { data: 'test' }, scope: :global)
      sleep 0.1

      expect(received).not_to be_nil
      expect(received.scope).to eq(:global)
    end

    it 'warns that cluster distribution is not implemented' do
      expect(Takagi.logger).to receive(:warn).with(/Cluster distribution is not implemented/)

      event_bus.publish('global.event', { data: 'test' }, scope: :global)
    end
  end

  describe 'Backward compatibility' do
    it 'works with existing code (no scope parameter)' do
      received = nil
      event_bus.consumer('legacy.event') do |msg|
        received = msg
      end

      event_bus.publish('legacy.event', { data: 'legacy' })
      sleep 0.1

      expect(received).not_to be_nil
      expect(received.scope).to eq(:local)
      expect(received.body).to eq({ data: 'legacy' })
    end

    it 'respects AddressPrefix.distributed? for legacy addresses' do
      # Legacy behavior: distributed addresses use CoAPBridge
      allow(Takagi::EventBus::AddressPrefix).to receive(:distributed?).with('sensor.temp').and_return(true)

      # Should still deliver locally
      received = nil
      event_bus.consumer('sensor.temp') do |msg|
        received = msg
      end

      event_bus.publish('sensor.temp', { value: 25.5 })
      sleep 0.1

      expect(received).not_to be_nil
    end
  end

  describe 'Real-world scenarios' do
    it 'handles system events (local)' do
      events = []
      event_bus.consumer('system.startup') { |msg| events << msg }
      event_bus.consumer('system.error') { |msg| events << msg }

      event_bus.publish('system.startup', { version: '1.0' }, scope: :local)
      event_bus.publish('system.error', { error: 'DB timeout' }, scope: :local)
      sleep 0.1

      expect(events.size).to eq(2)
      expect(events.all? { |e| e.scope == :local }).to be true
    end

    it 'handles cluster coordination (cluster)' do
      events = []
      event_bus.consumer('cache.invalidate') { |msg| events << msg }
      event_bus.consumer('config.reload') { |msg| events << msg }

      event_bus.publish('cache.invalidate', { key: 'user:123' }, scope: :cluster)
      event_bus.publish('config.reload', { section: 'auth' }, scope: :cluster)
      sleep 0.1

      expect(events.size).to eq(2)
      expect(events.all? { |e| e.scope == :cluster }).to be true
    end

    it 'handles telemetry (global)' do
      events = []
      event_bus.consumer('sensor.temperature') { |msg| events << msg }
      event_bus.consumer('telemetry.requests') { |msg| events << msg }

      event_bus.publish('sensor.temperature', { value: 25.5 }, scope: :global)
      event_bus.publish('telemetry.requests', { count: 1234 }, scope: :global)
      sleep 0.1

      expect(events.size).to eq(2)
      expect(events.all? { |e| e.scope == :global }).to be true
    end

    it 'handles mixed scopes in same application' do
      local_events = []
      cluster_events = []
      global_events = []

      event_bus.consumer('system.startup') { |msg| local_events << msg }
      event_bus.consumer('cache.invalidate') { |msg| cluster_events << msg }
      event_bus.consumer('sensor.temp') { |msg| global_events << msg }

      event_bus.publish('system.startup', { v: 1 }, scope: :local)
      event_bus.publish('cache.invalidate', { k: 'x' }, scope: :cluster)
      event_bus.publish('sensor.temp', { t: 25 }, scope: :global)
      sleep 0.1

      expect(local_events.size).to eq(1)
      expect(cluster_events.size).to eq(1)
      expect(global_events.size).to eq(1)

      expect(local_events.first.scope).to eq(:local)
      expect(cluster_events.first.scope).to eq(:cluster)
      expect(global_events.first.scope).to eq(:global)
    end
  end

  describe 'Message buffering with scope' do
    it 'buffers messages with scope information' do
      # Use a distributed address prefix so MessageBuffer stores it
      event_bus.enable_message_buffering
      event_bus.publish('sensor.buffered', { data: 'test' }, scope: :cluster)
      sleep 0.1

      messages = event_bus.replay('sensor.buffered')
      event_bus.disable_message_buffering

      expect(messages.size).to eq(1)
      expect(messages.first.scope).to eq(:cluster)
    end

    it 'buffers messages with different scopes' do
      # Use a distributed address prefix
      event_bus.enable_message_buffering
      event_bus.publish('sensor.multi', { v: 1 }, scope: :local)
      event_bus.publish('sensor.multi', { v: 2 }, scope: :cluster)
      event_bus.publish('sensor.multi', { v: 3 }, scope: :global)
      sleep 0.1

      messages = event_bus.replay('sensor.multi')
      event_bus.disable_message_buffering

      # MessageBuffer stores all messages for distributed addresses (sensor.*)
      # regardless of scope - useful for late joiners
      expect(messages.size).to eq(3)
      expect(messages.map(&:scope)).to eq([:local, :cluster, :global])
    end
  end
end
