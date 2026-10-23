# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Takagi::Bus::Future do
  describe '#set_value' do
    it 'sets the value successfully' do
      future = described_class.new
      future.set_value(42)

      expect(future.value).to eq(42)
    end

    it 'raises error if already completed' do
      future = described_class.new
      future.set_value(42)

      expect { future.set_value(43) }.to raise_error('Future already completed')
    end

    it 'marks future as completed' do
      future = described_class.new
      expect(future.completed?).to be false

      future.set_value(42)
      expect(future.completed?).to be true
    end
  end

  describe '#set_error' do
    it 'sets error successfully' do
      future = described_class.new
      error = StandardError.new('Test error')
      future.set_error(error)

      expect { future.value }.to raise_error(StandardError, 'Test error')
    end

    it 'raises error if already completed' do
      future = described_class.new
      future.set_error(StandardError.new('Error 1'))

      expect { future.set_error(StandardError.new('Error 2')) }.to raise_error('Future already completed')
    end

    it 'marks future as completed' do
      future = described_class.new
      future.set_error(StandardError.new('Error'))

      expect(future.completed?).to be true
    end
  end

  describe '#value' do
    it 'returns value immediately if already completed' do
      future = described_class.new
      future.set_value(42)

      expect(future.value).to eq(42)
    end

    it 'blocks until value is set' do
      future = described_class.new

      Thread.new do
        sleep 0.1
        future.set_value(42)
      end

      start = Time.now
      result = future.value
      elapsed = Time.now - start

      expect(result).to eq(42)
      expect(elapsed).to be >= 0.1
    end

    it 'raises error if timeout expires' do
      future = described_class.new

      expect {
        future.value(timeout: 0.1)
      }.to raise_error(Timeout::Error)
    end

    it 'returns value before timeout expires' do
      future = described_class.new

      Thread.new do
        sleep 0.05
        future.set_value(42)
      end

      result = future.value(timeout: 0.2)
      expect(result).to eq(42)
    end

    it 'raises the set error' do
      future = described_class.new
      error = ArgumentError.new('Invalid argument')
      future.set_error(error)

      expect { future.value }.to raise_error(ArgumentError, 'Invalid argument')
    end

    it 'waits indefinitely without timeout' do
      future = described_class.new

      Thread.new do
        sleep 0.2
        future.set_value('delayed')
      end

      result = future.value
      expect(result).to eq('delayed')
    end
  end

  describe '#completed?' do
    it 'returns false for new future' do
      future = described_class.new
      expect(future.completed?).to be false
    end

    it 'returns true after set_value' do
      future = described_class.new
      future.set_value(42)
      expect(future.completed?).to be true
    end

    it 'returns true after set_error' do
      future = described_class.new
      future.set_error(StandardError.new('Error'))
      expect(future.completed?).to be true
    end
  end

  describe '#error?' do
    it 'returns false for new future' do
      future = described_class.new
      expect(future.error?).to be false
    end

    it 'returns false for successful completion' do
      future = described_class.new
      future.set_value(42)
      expect(future.error?).to be false
    end

    it 'returns true for error completion' do
      future = described_class.new
      future.set_error(StandardError.new('Error'))
      expect(future.error?).to be true
    end
  end

  describe '#success?' do
    it 'returns false for new future' do
      future = described_class.new
      expect(future.success?).to be false
    end

    it 'returns true for successful completion' do
      future = described_class.new
      future.set_value(42)
      expect(future.success?).to be true
    end

    it 'returns false for error completion' do
      future = described_class.new
      future.set_error(StandardError.new('Error'))
      expect(future.success?).to be false
    end
  end

  describe '#error' do
    it 'returns nil for new future' do
      future = described_class.new
      expect(future.error).to be_nil
    end

    it 'returns nil for successful completion' do
      future = described_class.new
      future.set_value(42)
      expect(future.error).to be_nil
    end

    it 'returns error for error completion' do
      future = described_class.new
      error = RuntimeError.new('Failed')
      future.set_error(error)
      expect(future.error).to eq(error)
    end
  end

  describe '#try_value' do
    it 'returns nil for incomplete future' do
      future = described_class.new
      expect(future.try_value).to be_nil
    end

    it 'returns value immediately if completed' do
      future = described_class.new
      future.set_value(42)
      expect(future.try_value).to eq(42)
    end

    it 'raises error if completed with error' do
      future = described_class.new
      future.set_error(StandardError.new('Error'))
      expect { future.try_value }.to raise_error(StandardError, 'Error')
    end

    it 'does not block' do
      future = described_class.new

      start = Time.now
      result = future.try_value
      elapsed = Time.now - start

      expect(result).to be_nil
      expect(elapsed).to be < 0.01
    end
  end

  describe '#wait' do
    it 'returns true when completed' do
      future = described_class.new
      future.set_value(42)
      expect(future.wait).to be true
    end

    it 'blocks until completion' do
      future = described_class.new

      Thread.new do
        sleep 0.1
        future.set_value(42)
      end

      start = Time.now
      result = future.wait
      elapsed = Time.now - start

      expect(result).to be true
      expect(elapsed).to be >= 0.1
    end

    it 'returns false on timeout' do
      future = described_class.new
      result = future.wait(timeout: 0.05)
      expect(result).to be false
    end

    it 'returns true if completed before timeout' do
      future = described_class.new

      Thread.new do
        sleep 0.05
        future.set_value(42)
      end

      result = future.wait(timeout: 0.2)
      expect(result).to be true
    end

    it 'does not raise error even if future has error' do
      future = described_class.new
      future.set_error(StandardError.new('Error'))
      expect(future.wait).to be true
    end
  end

  describe 'concurrency' do
    it 'handles multiple threads waiting' do
      future = described_class.new
      results = []
      mutex = Mutex.new

      # Start multiple waiting threads
      threads = 5.times.map do
        Thread.new do
          value = future.value
          mutex.synchronize { results << value }
        end
      end

      # Set value after all threads are waiting
      sleep 0.1
      future.set_value(42)

      threads.each(&:join)

      expect(results.size).to eq(5)
      expect(results.uniq).to eq([42])
    end

    it 'handles concurrent set attempts' do
      future = described_class.new
      errors = []
      mutex = Mutex.new

      threads = 5.times.map do
        Thread.new do
          begin
            future.set_value(rand(100))
          rescue => e
            mutex.synchronize { errors << e }
          end
        end
      end

      threads.each(&:join)

      # One should succeed, others should get error
      expect(errors.size).to eq(4)
      expect(errors.all? { |e| e.message == 'Future already completed' }).to be true
      expect(future.completed?).to be true
    end

    it 'notifies all waiting threads' do
      future = described_class.new
      waiting_count = 10
      completed_count = 0
      mutex = Mutex.new

      threads = waiting_count.times.map do
        Thread.new do
          future.value(timeout: 1.0)
          mutex.synchronize { completed_count += 1 }
        end
      end

      sleep 0.1
      future.set_value('done')
      threads.each(&:join)

      expect(completed_count).to eq(waiting_count)
    end
  end

  describe 'edge cases' do
    it 'handles nil value' do
      future = described_class.new
      future.set_value(nil)
      expect(future.value).to be_nil
    end

    it 'handles false value' do
      future = described_class.new
      future.set_value(false)
      expect(future.value).to be false
    end

    it 'handles complex objects' do
      future = described_class.new
      data = { users: [{ id: 1, name: 'Alice' }], total: 1 }
      future.set_value(data)
      expect(future.value).to eq(data)
    end

    it 'handles very short timeouts' do
      future = described_class.new
      expect {
        future.value(timeout: 0.001)
      }.to raise_error(Timeout::Error)
    end
  end
end