# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Takagi::Bus::LRUCache do
  describe '#initialize' do
    it 'creates cache with default settings' do
      cache = described_class.new
      expect(cache.max_size).to eq(1000)
      expect(cache.ttl).to eq(3600)
    end

    it 'creates cache with custom settings' do
      cache = described_class.new(100, 300)
      expect(cache.max_size).to eq(100)
      expect(cache.ttl).to eq(300)
    end
  end

  describe '#set and #get' do
    it 'stores and retrieves values' do
      cache = described_class.new
      cache.set('key1', 'value1')
      expect(cache.get('key1')).to eq('value1')
    end

    it 'returns nil for missing keys' do
      cache = described_class.new
      expect(cache.get('missing')).to be_nil
    end

    it 'updates existing keys' do
      cache = described_class.new
      cache.set('key1', 'value1')
      cache.set('key1', 'value2')
      expect(cache.get('key1')).to eq('value2')
    end

    it 'supports various data types' do
      cache = described_class.new

      cache.set('string', 'hello')
      cache.set('number', 42)
      cache.set('array', [1, 2, 3])
      cache.set('hash', { a: 1, b: 2 })

      expect(cache.get('string')).to eq('hello')
      expect(cache.get('number')).to eq(42)
      expect(cache.get('array')).to eq([1, 2, 3])
      expect(cache.get('hash')).to eq({ a: 1, b: 2 })
    end
  end

  describe 'LRU eviction' do
    it 'evicts least recently used items when at capacity' do
      cache = described_class.new(3, 3600)

      cache.set('key1', 'value1')
      cache.set('key2', 'value2')
      cache.set('key3', 'value3')

      # Cache is full (3/3)
      expect(cache.size).to eq(3)

      # Adding 4th item should evict key1 (oldest)
      cache.set('key4', 'value4')

      expect(cache.size).to eq(3)
      expect(cache.get('key1')).to be_nil
      expect(cache.get('key2')).to eq('value2')
      expect(cache.get('key3')).to eq('value3')
      expect(cache.get('key4')).to eq('value4')
    end

    it 'updates access order on get' do
      cache = described_class.new(3, 3600)

      cache.set('key1', 'value1')
      cache.set('key2', 'value2')
      cache.set('key3', 'value3')

      # Access key1 (makes it most recently used)
      cache.get('key1')

      # Add key4 (should evict key2, not key1)
      cache.set('key4', 'value4')

      expect(cache.get('key1')).to eq('value1')
      expect(cache.get('key2')).to be_nil
      expect(cache.get('key3')).to eq('value3')
      expect(cache.get('key4')).to eq('value4')
    end

    it 'does not evict when updating existing key' do
      cache = described_class.new(3, 3600)

      cache.set('key1', 'value1')
      cache.set('key2', 'value2')
      cache.set('key3', 'value3')

      # Update existing key
      cache.set('key2', 'new_value2')

      expect(cache.size).to eq(3)
      expect(cache.get('key1')).to eq('value1')
      expect(cache.get('key2')).to eq('new_value2')
      expect(cache.get('key3')).to eq('value3')
    end
  end

  describe 'TTL expiration' do
    it 'expires entries after TTL' do
      cache = described_class.new(100, 0.1) # 100ms TTL

      cache.set('key1', 'value1')
      expect(cache.get('key1')).to eq('value1')

      # Wait for expiration
      sleep 0.15

      expect(cache.get('key1')).to be_nil
    end

    it 'cleans up expired entries on get' do
      cache = described_class.new(100, 0.1)

      cache.set('key1', 'value1')
      cache.set('key2', 'value2')

      sleep 0.15

      # Accessing cache should trigger cleanup
      cache.get('key1')

      expect(cache.size).to eq(0)
    end

    it 'cleans up expired entries on set' do
      cache = described_class.new(100, 0.1)

      cache.set('key1', 'value1')
      sleep 0.15

      # Setting new value should trigger cleanup
      cache.set('key2', 'value2')

      expect(cache.size).to eq(1)
      expect(cache.get('key1')).to be_nil
      expect(cache.get('key2')).to eq('value2')
    end

    it 'refreshes TTL on get' do
      cache = described_class.new(100, 0.2)

      cache.set('key1', 'value1')
      sleep 0.1

      # Access refreshes TTL
      cache.get('key1')
      sleep 0.15

      # Should still be valid (0.1 + 0.15 = 0.25, but TTL refreshed at 0.1)
      expect(cache.get('key1')).to eq('value1')
    end
  end

  describe '#delete' do
    it 'removes entry from cache' do
      cache = described_class.new

      cache.set('key1', 'value1')
      expect(cache.get('key1')).to eq('value1')

      cache.delete('key1')
      expect(cache.get('key1')).to be_nil
    end

    it 'returns deleted value' do
      cache = described_class.new

      cache.set('key1', 'value1')
      result = cache.delete('key1')

      expect(result).to eq('value1')
    end

    it 'handles deleting non-existent key' do
      cache = described_class.new
      expect { cache.delete('missing') }.not_to raise_error
    end
  end

  describe '#clear' do
    it 'removes all entries' do
      cache = described_class.new

      cache.set('key1', 'value1')
      cache.set('key2', 'value2')
      cache.set('key3', 'value3')

      expect(cache.size).to eq(3)

      cache.clear

      expect(cache.size).to eq(0)
      expect(cache.get('key1')).to be_nil
      expect(cache.get('key2')).to be_nil
      expect(cache.get('key3')).to be_nil
    end
  end

  describe '#size' do
    it 'returns number of entries' do
      cache = described_class.new

      expect(cache.size).to eq(0)

      cache.set('key1', 'value1')
      expect(cache.size).to eq(1)

      cache.set('key2', 'value2')
      expect(cache.size).to eq(2)

      cache.delete('key1')
      expect(cache.size).to eq(1)
    end
  end

  describe '#empty?' do
    it 'returns true when empty' do
      cache = described_class.new
      expect(cache.empty?).to be true
    end

    it 'returns false when not empty' do
      cache = described_class.new
      cache.set('key1', 'value1')
      expect(cache.empty?).to be false
    end
  end

  describe '#key?' do
    it 'returns true for existing keys' do
      cache = described_class.new
      cache.set('key1', 'value1')
      expect(cache.key?('key1')).to be true
    end

    it 'returns false for missing keys' do
      cache = described_class.new
      expect(cache.key?('missing')).to be false
    end

    it 'returns false for expired keys' do
      cache = described_class.new(100, 0.1)
      cache.set('key1', 'value1')

      sleep 0.15
      expect(cache.key?('key1')).to be false
    end
  end

  describe '#keys' do
    it 'returns all keys' do
      cache = described_class.new

      cache.set('key1', 'value1')
      cache.set('key2', 'value2')
      cache.set('key3', 'value3')

      expect(cache.keys).to match_array(['key1', 'key2', 'key3'])
    end

    it 'excludes expired keys' do
      cache = described_class.new(100, 0.1)

      cache.set('key1', 'value1')
      cache.set('key2', 'value2')

      sleep 0.15

      expect(cache.keys).to eq([])
    end
  end

  describe '#stats' do
    it 'returns cache statistics' do
      cache = described_class.new(100, 300)

      cache.set('key1', 'value1')
      cache.set('key2', 'value2')

      stats = cache.stats

      expect(stats[:size]).to eq(2)
      expect(stats[:max_size]).to eq(100)
      expect(stats[:ttl]).to eq(300)
      expect(stats[:utilization]).to eq(2.0)
    end
  end

  describe 'thread safety' do
    it 'handles concurrent reads and writes' do
      cache = described_class.new(1000, 3600)
      threads = []
      results = []
      mutex = Mutex.new

      # Writer threads
      5.times do |i|
        threads << Thread.new do
          10.times do |j|
            cache.set("key#{i}-#{j}", "value#{i}-#{j}")
          end
        end
      end

      # Reader threads
      5.times do
        threads << Thread.new do
          10.times do |j|
            value = cache.get("key0-#{j}")
            mutex.synchronize { results << value } if value
          end
        end
      end

      threads.each(&:join)

      # Should have data without errors
      expect(cache.size).to be > 0
      expect { cache.keys }.not_to raise_error
    end

    it 'maintains consistency under concurrent access' do
      cache = described_class.new(10, 3600)
      threads = []

      # Multiple threads trying to fill cache beyond capacity
      10.times do |i|
        threads << Thread.new do
          20.times do |j|
            cache.set("thread#{i}-key#{j}", "value#{j}")
          end
        end
      end

      threads.each(&:join)

      # Size should not exceed max_size
      expect(cache.size).to be <= 10
    end
  end
end