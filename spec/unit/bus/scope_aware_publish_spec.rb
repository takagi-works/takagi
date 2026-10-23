# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Takagi::Bus, 'local publishing' do
  let(:event_bus) { described_class }

  # Deliberately no process-wide teardown hook: `described_class` IS the shared
  # default bus, so shutting it down here would poison any later example that
  # needs delivery. `Bus#shutdown` is not terminal any more and the
  # shutdown-recovery behaviour is pinned in `spec/unit/bus/bus_shutdown_spec.rb`
  # (row 10 of .omo/plans/local-bus.md).

  describe 'local delivery' do
    it 'delivers a published message to its consumer' do
      received = nil
      event_bus.consumer('local.event') { |msg| received = msg }

      event_bus.publish('local.event', { data: 'test' })

      expect(received).not_to be_nil
      expect(received.body).to eq({ data: 'test' })
    end

    it 'accepts an explicit :local scope and still delivers locally' do
      received = nil
      event_bus.consumer('scoped.local.event') { |msg| received = msg }

      event_bus.publish('scoped.local.event', { data: 'test' }, scope: :local)

      expect(received).not_to be_nil
      expect(received.body).to eq({ data: 'test' })
    end

    it 'delivers in publication order without waiting for a pool' do
      received = []
      event_bus.consumer('ordered.event') { |msg| received << msg.body[:n] }

      event_bus.publish('ordered.event', { n: 1 })
      event_bus.publish('ordered.event', { n: 2 })
      event_bus.publish('ordered.event', { n: 3 })

      expect(received).to eq([1, 2, 3])
    end

    it 'works with existing code (no scope parameter)' do
      received = nil
      event_bus.consumer('legacy.event') { |msg| received = msg }

      event_bus.publish('legacy.event', { data: 'legacy' })

      expect(received).not_to be_nil
      expect(received.body).to eq({ data: 'legacy' })
    end
  end

  describe 'remote scope refusal' do
    it 'raises ArgumentError naming the planned remote work for scope: :cluster' do
      expect { event_bus.publish('cluster.event', { data: 'test' }, scope: :cluster) }
        .to raise_error(ArgumentError, /remote|relay/)
    end

    it 'raises ArgumentError naming the planned remote work for scope: :global' do
      expect { event_bus.publish('global.event', { data: 'test' }, scope: :global) }
        .to raise_error(ArgumentError, /remote|relay/)
    end

    it 'refuses the scope before any consumer is called' do
      received = []
      event_bus.consumer('refused.event') { |msg| received << msg }

      expect { event_bus.publish('refused.event', { data: 'test' }, scope: :global) }
        .to raise_error(ArgumentError)

      expect(received).to be_empty
    end
  end

  describe 'real-world local scenarios' do
    it 'delivers two addresses to their own subscribers in publication order' do
      events = []
      event_bus.consumer('system.startup') { |msg| events << msg }
      event_bus.consumer('system.error') { |msg| events << msg }

      event_bus.publish('system.startup', { version: '1.0' })
      event_bus.publish('system.error', { error: 'DB timeout' })

      expect(events.map(&:address)).to eq(%w[system.startup system.error])
    end
  end
end
