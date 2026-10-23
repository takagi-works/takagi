# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Takagi::Bus::MessageBuffer do
  let(:message1) { Takagi::Bus::Message.new('sensor.temp', { value: 20 }) }
  let(:message2) { Takagi::Bus::Message.new('sensor.temp', { value: 21 }) }
  let(:message3) { Takagi::Bus::Message.new('sensor.temp', { value: 22 }) }

  after do
    # Ensure cleanup threads are stopped
    subject.shutdown
  end

  describe '#initialize' do
    it 'creates buffer with default settings' do
      buffer = described_class.new
      expect(buffer.enabled?).to be true
    end

    it 'creates buffer with custom settings' do
      buffer = described_class.new(max_messages: 50, ttl: 600)
      stats = buffer.stats
      expect(stats[:max_messages_per_address]).to eq(50)
      expect(stats[:ttl]).to eq(600)
      buffer.shutdown
    end

    it 'starts cleanup thread' do
      buffer = described_class.new
      expect(buffer.instance_variable_get(:@cleanup_thread)).to be_alive
      buffer.shutdown
    end
  end

  describe '#store' do
    it 'stores messages for distributed addresses' do
      buffer = described_class.new

      buffer.store('sensor.temperature.room1', message1)

      messages = buffer.replay('sensor.temperature.room1')
      expect(messages.size).to eq(1)
      expect(messages.first.body).to eq({ value: 20 })
      buffer.shutdown
    end

    it 'stores messages for every address it is given' do
      buffer = described_class.new

      # The buffer no longer filters by address prefix: the bus owns no
      # distribution policy, so a standalone buffer keeps what it is handed.
      buffer.store('system.startup', message1)

      messages = buffer.replay('system.startup')
      expect(messages.size).to eq(1)
      buffer.shutdown
    end

    it 'stores multiple messages for same address' do
      buffer = described_class.new

      buffer.store('sensor.temp', message1)
      buffer.store('sensor.temp', message2)
      buffer.store('sensor.temp', message3)

      messages = buffer.replay('sensor.temp')
      expect(messages.size).to eq(3)
      buffer.shutdown
    end

    it 'does not store when disabled' do
      buffer = described_class.new
      buffer.disable

      buffer.store('sensor.temp', message1)

      messages = buffer.replay('sensor.temp')
      expect(messages).to be_empty
      buffer.shutdown
    end
  end

  describe 'ring buffer eviction' do
    it 'evicts oldest messages when at capacity' do
      buffer = described_class.new(max_messages: 3, ttl: 300)

      4.times do |i|
        msg = Takagi::Bus::Message.new('sensor.temp', { value: i })
        buffer.store('sensor.temp', msg)
      end

      messages = buffer.replay('sensor.temp')
      expect(messages.size).to eq(3)
      expect(messages.first.body[:value]).to eq(1) # First message (value: 0) was evicted
      expect(messages.last.body[:value]).to eq(3)
      buffer.shutdown
    end

    it 'maintains separate buffers per address' do
      buffer = described_class.new(max_messages: 2, ttl: 300)

      buffer.store('sensor.temp.room1', Takagi::Bus::Message.new('sensor.temp.room1', { room: 1 }))
      buffer.store('sensor.temp.room2', Takagi::Bus::Message.new('sensor.temp.room2', { room: 2 }))

      room1_messages = buffer.replay('sensor.temp.room1')
      room2_messages = buffer.replay('sensor.temp.room2')

      expect(room1_messages.size).to eq(1)
      expect(room2_messages.size).to eq(1)
      expect(room1_messages.first.body[:room]).to eq(1)
      expect(room2_messages.first.body[:room]).to eq(2)
      buffer.shutdown
    end
  end

  describe '#replay' do
    it 'returns all messages when since is nil' do
      buffer = described_class.new

      buffer.store('sensor.temp', message1)
      buffer.store('sensor.temp', message2)

      messages = buffer.replay('sensor.temp')
      expect(messages.size).to eq(2)
      buffer.shutdown
    end

    it 'returns messages since given timestamp' do
      buffer = described_class.new

      # Store first message
      buffer.store('sensor.temp', message1)
      sleep 0.05

      # Record timestamp
      since_time = Time.now
      sleep 0.05

      # Store second message
      buffer.store('sensor.temp', message2)

      messages = buffer.replay('sensor.temp', since: since_time)
      expect(messages.size).to eq(1)
      expect(messages.first.body[:value]).to eq(21)
      buffer.shutdown
    end

    it 'returns empty array for non-existent address' do
      buffer = described_class.new

      messages = buffer.replay('nonexistent.address')
      expect(messages).to be_empty
      buffer.shutdown
    end
  end

  describe '#store_failed' do
    it 'stores failed message with metadata' do
      buffer = described_class.new

      buffer.store_failed('sensor.temp', message1, 'coap://remote:5683')

      messages = buffer.replay('sensor.temp')
      expect(messages.size).to eq(1)
      expect(messages.first.headers[:failed_destination]).to eq('coap://remote:5683')
      expect(messages.first.headers[:failed_at]).to be_a(Time)
      buffer.shutdown
    end

    it 'stores failed message without destination' do
      buffer = described_class.new

      buffer.store_failed('sensor.temp', message1)

      messages = buffer.replay('sensor.temp')
      expect(messages.size).to eq(1)
      expect(messages.first.headers[:failed_at]).to be_a(Time)
      expect(messages.first.headers[:failed_destination]).to be_nil
      buffer.shutdown
    end
  end

  describe '#all' do
    it 'returns all buffered messages' do
      buffer = described_class.new

      buffer.store('sensor.temp', message1)
      buffer.store('sensor.temp', message2)

      messages = buffer.all('sensor.temp')
      expect(messages.size).to eq(2)
      buffer.shutdown
    end
  end

  describe '#size' do
    it 'returns buffer size for address' do
      buffer = described_class.new

      expect(buffer.size('sensor.temp')).to eq(0)

      buffer.store('sensor.temp', message1)
      expect(buffer.size('sensor.temp')).to eq(1)

      buffer.store('sensor.temp', message2)
      expect(buffer.size('sensor.temp')).to eq(2)
      buffer.shutdown
    end
  end

  describe '#total_size' do
    it 'returns total messages across all addresses' do
      buffer = described_class.new

      buffer.store('sensor.temp.room1', Takagi::Bus::Message.new('sensor.temp.room1', { room: 1 }))
      buffer.store('sensor.temp.room2', Takagi::Bus::Message.new('sensor.temp.room2', { room: 2 }))

      expect(buffer.total_size).to eq(2)
      buffer.shutdown
    end
  end

  describe '#clear' do
    it 'clears buffer for specific address' do
      buffer = described_class.new

      buffer.store('sensor.temp', message1)
      buffer.store('sensor.temp', message2)

      buffer.clear('sensor.temp')

      messages = buffer.replay('sensor.temp')
      expect(messages).to be_empty
      buffer.shutdown
    end
  end

  describe '#clear_all' do
    it 'clears all buffers' do
      buffer = described_class.new

      buffer.store('sensor.temp.room1', Takagi::Bus::Message.new('sensor.temp.room1', { room: 1 }))
      buffer.store('sensor.temp.room2', Takagi::Bus::Message.new('sensor.temp.room2', { room: 2 }))

      buffer.clear_all

      expect(buffer.total_size).to eq(0)
      buffer.shutdown
    end
  end

  describe '#enable and #disable' do
    it 'enables and disables buffering' do
      buffer = described_class.new

      expect(buffer.enabled?).to be true

      buffer.disable
      expect(buffer.enabled?).to be false

      buffer.enable
      expect(buffer.enabled?).to be true
      buffer.shutdown
    end
  end

  describe '#stats' do
    it 'returns buffer statistics' do
      buffer = described_class.new(max_messages: 100, ttl: 300)

      buffer.store('sensor.temp', message1)
      buffer.store('sensor.humidity', Takagi::Bus::Message.new('sensor.humidity', { value: 60 }))

      stats = buffer.stats
      expect(stats[:enabled]).to be true
      expect(stats[:addresses]).to eq(2)
      expect(stats[:total_messages]).to eq(2)
      expect(stats[:max_messages_per_address]).to eq(100)
      expect(stats[:ttl]).to eq(300)
      expect(stats[:buffers]).to be_a(Hash)
      buffer.shutdown
    end
  end

  describe 'TTL expiration' do
    it 'expires messages after TTL' do
      buffer = described_class.new(max_messages: 100, ttl: 0.1) # 100ms TTL

      buffer.store('sensor.temp', message1)
      expect(buffer.size('sensor.temp')).to eq(1)

      # Wait for expiration and cleanup
      sleep 0.2

      # Trigger cleanup by storing new message
      buffer.store('sensor.temp', message2)

      # Old message should be cleaned up
      messages = buffer.replay('sensor.temp')
      expect(messages.size).to eq(1)
      expect(messages.first.body[:value]).to eq(21)
      buffer.shutdown
    end

    it 'removes empty buffers after cleanup' do
      buffer = described_class.new(max_messages: 100, ttl: 0.1)

      buffer.store('sensor.temp', message1)
      stats = buffer.stats
      expect(stats[:addresses]).to eq(1)

      # Wait for expiration and cleanup
      sleep 0.2

      # Trigger cleanup
      buffer.instance_variable_get(:@mutex).synchronize do
        buffer.instance_variable_get(:@buffers).each_value do |ring_buffer|
          ring_buffer.clean_expired(buffer.instance_variable_get(:@ttl))
        end
        buffer.instance_variable_get(:@buffers).delete_if { |_addr, ring_buf| ring_buf.size.zero? }
      end

      stats = buffer.stats
      expect(stats[:addresses]).to eq(0)
      buffer.shutdown
    end
  end

  describe 'thread safety' do
    it 'handles concurrent writes' do
      buffer = described_class.new(max_messages: 1000, ttl: 300)
      threads = []

      # Multiple threads writing messages
      5.times do |i|
        threads << Thread.new do
          10.times do |j|
            msg = Takagi::Bus::Message.new("sensor.temp.#{i}", { value: j })
            buffer.store("sensor.temp.#{i}", msg)
          end
        end
      end

      threads.each(&:join)

      # Should have all messages without errors
      expect(buffer.total_size).to eq(50)
      buffer.shutdown
    end

    it 'handles concurrent reads and writes' do
      buffer = described_class.new(max_messages: 100, ttl: 300)
      threads = []
      read_results = []
      mutex = Mutex.new

      # Writer thread
      threads << Thread.new do
        10.times do |i|
          msg = Takagi::Bus::Message.new('sensor.temp', { value: i })
          buffer.store('sensor.temp', msg)
          sleep 0.01
        end
      end

      # Reader threads
      3.times do
        threads << Thread.new do
          5.times do
            messages = buffer.replay('sensor.temp')
            mutex.synchronize { read_results << messages.size }
            sleep 0.01
          end
        end
      end

      threads.each(&:join)

      # Should complete without errors
      expect(read_results.size).to eq(15)
      expect { buffer.stats }.not_to raise_error
      buffer.shutdown
    end
  end

  describe '#shutdown' do
    it 'stops cleanup thread' do
      buffer = described_class.new
      thread = buffer.instance_variable_get(:@cleanup_thread)

      expect(thread).to be_alive

      buffer.shutdown
      sleep 0.05

      expect(thread).not_to be_alive
    end

    it 'can be called multiple times safely' do
      buffer = described_class.new

      expect { buffer.shutdown }.not_to raise_error
      expect { buffer.shutdown }.not_to raise_error
    end
  end
end