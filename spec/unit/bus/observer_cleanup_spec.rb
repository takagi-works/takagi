# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Takagi::Bus::ObserverCleanup do
  describe '#initialize' do
    it 'creates cleanup with default settings' do
      cleanup = described_class.new
      expect(cleanup.interval).to eq(60)
      expect(cleanup.max_age).to eq(600)
    end

    it 'creates cleanup with custom settings' do
      cleanup = described_class.new(interval: 30, max_age: 300)
      expect(cleanup.interval).to eq(30)
      expect(cleanup.max_age).to eq(300)
    end
  end

  describe '#start' do
    it 'starts the cleanup thread' do
      cleanup = described_class.new(interval: 1, max_age: 60)
      expect(cleanup.running?).to be false

      cleanup.start
      expect(cleanup.running?).to be true

      cleanup.stop
    end

    it 'is idempotent' do
      cleanup = described_class.new(interval: 1, max_age: 60)

      cleanup.start
      cleanup.start # Should not error

      expect(cleanup.running?).to be true
      cleanup.stop
    end

    it 'creates a named thread' do
      cleanup = described_class.new(interval: 1, max_age: 60)
      cleanup.start

      sleep 0.1
      thread = Thread.list.find { |t| t.name == 'ObserverCleanup' }
      expect(thread).not_to be_nil

      cleanup.stop
    end
  end

  describe '#stop' do
    it 'stops the cleanup thread' do
      cleanup = described_class.new(interval: 1, max_age: 60)

      cleanup.start
      expect(cleanup.running?).to be true

      cleanup.stop
      expect(cleanup.running?).to be false
    end

    it 'is idempotent' do
      cleanup = described_class.new(interval: 1, max_age: 60)

      cleanup.start
      cleanup.stop
      cleanup.stop # Should not error

      expect(cleanup.running?).to be false
    end

    it 'waits for thread to finish' do
      cleanup = described_class.new(interval: 1, max_age: 60)

      cleanup.start
      thread = cleanup.instance_variable_get(:@thread)
      sleep 0.1
      cleanup.stop

      expect(thread.alive?).to be false
    end
  end

  describe '#running?' do
    it 'returns true when running' do
      cleanup = described_class.new(interval: 1, max_age: 60)
      cleanup.start

      expect(cleanup.running?).to be true

      cleanup.stop
    end

    it 'returns false when stopped' do
      cleanup = described_class.new(interval: 1, max_age: 60)
      expect(cleanup.running?).to be false
    end
  end

  describe '#stats' do
    it 'returns initial statistics' do
      cleanup = described_class.new(interval: 1, max_age: 60)
      stats = cleanup.stats

      expect(stats[:runs]).to eq(0)
      expect(stats[:cleaned]).to eq(0)
      expect(stats[:errors]).to eq(0)
    end

    it 'tracks cleanup runs' do
      cleanup = described_class.new(interval: 0.1, max_age: 60)

      cleanup.start
      sleep 0.25 # Should run at least 2 times

      stats = cleanup.stats
      expect(stats[:runs]).to be >= 2

      cleanup.stop
    end

    it 'is thread-safe' do
      cleanup = described_class.new(interval: 0.05, max_age: 60)

      cleanup.start

      threads = 5.times.map do
        Thread.new do
          10.times { cleanup.stats }
        end
      end

      threads.each(&:join)
      cleanup.stop

      expect { cleanup.stats }.not_to raise_error
    end
  end

  describe '#cleanup_now' do
    it 'runs cleanup immediately' do
      cleanup = described_class.new(interval: 100, max_age: 60)
      initial_runs = cleanup.stats[:runs]

      cleanup.cleanup_now

      expect(cleanup.stats[:runs]).to eq(initial_runs + 1)
    end

    it 'can be called without starting thread' do
      cleanup = described_class.new(interval: 100, max_age: 60)

      expect { cleanup.cleanup_now }.not_to raise_error
      expect(cleanup.stats[:runs]).to eq(1)
    end

    it 'increments cleaned stats using ObserveRegistry cleanup count' do
      cleanup = described_class.new(interval: 100, max_age: 42)
      allow(Takagi::ObserveRegistry).to receive(:cleanup_stale_observers).and_return(3)

      cleanup.cleanup_now

      stats = cleanup.stats
      expect(Takagi::ObserveRegistry).to have_received(:cleanup_stale_observers).with(max_age: 42)
      expect(stats[:cleaned]).to eq(3)
    end
  end

  describe 'periodic cleanup' do
    it 'runs cleanup periodically' do
      cleanup = described_class.new(interval: 0.1, max_age: 60)

      cleanup.start
      initial_runs = cleanup.stats[:runs]

      sleep 0.35

      final_runs = cleanup.stats[:runs]
      expect(final_runs - initial_runs).to be >= 3

      cleanup.stop
    end

    it 'handles errors gracefully' do
      cleanup = described_class.new(interval: 0.1, max_age: 60)

      # Even if cleanup logic throws errors, thread should continue
      cleanup.start
      sleep 0.25

      expect(cleanup.running?).to be true
      cleanup.stop
    end
  end

  describe 'lifecycle' do
    it 'can be started and stopped multiple times' do
      cleanup = described_class.new(interval: 0.1, max_age: 60)

      cleanup.start
      sleep 0.15
      cleanup.stop

      first_runs = cleanup.stats[:runs]

      cleanup.start
      sleep 0.15
      cleanup.stop

      second_runs = cleanup.stats[:runs]

      expect(second_runs).to be > first_runs
    end
  end
end
