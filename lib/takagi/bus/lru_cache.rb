# frozen_string_literal: true

module Takagi
  class Bus
    # Thread-safe LRU cache with TTL (pure Ruby)
    # Zero runtime dependencies
    #
    # Features:
    # - Least Recently Used eviction when at capacity
    # - Time-To-Live (TTL) based expiration
    # - Thread-safe with Mutex
    #
    # @example
    #   cache = LRUCache.new(max_size: 1000, ttl: 3600)
    #   cache.set('key', 'value')
    #   cache.get('key') # => 'value'
    #   cache.size # => 1
    class LRUCache
      attr_reader :max_size, :ttl

      # Initialize LRU cache
      # @param max_size [Integer] Maximum number of entries (default: 1000)
      # @param ttl [Integer] Time-to-live in seconds (default: 3600)
      def initialize(max_size = 1000, ttl = 3600)
        @max_size = max_size
        @ttl = ttl
        @cache = {}
        @access_order = []
        @timestamps = {}
        @mutex = Mutex.new
      end

      # Get value from cache
      # @param key [Object] Cache key
      # @return [Object, nil] Cached value or nil if not found/expired
      def get(key)
        @mutex.synchronize do
          cleanup_expired
          return nil unless @cache.key?(key)

          # Update access order (move to end = most recently used)
          @access_order.delete(key)
          @access_order << key
          @timestamps[key] = Time.now

          @cache[key]
        end
      end

      # Set value in cache
      # @param key [Object] Cache key
      # @param value [Object] Value to cache
      def set(key, value)
        @mutex.synchronize do
          cleanup_expired

          # Remove oldest entry if at capacity and key is new
          evict_oldest if @cache.size >= @max_size && !@cache.key?(key)

          # Add/update entry
          @access_order.delete(key) # Remove if exists
          @access_order << key      # Add to end (most recently used)
          @cache[key] = value
          @timestamps[key] = Time.now
        end
      end

      # Delete entry from cache
      # @param key [Object] Cache key
      # @return [Object, nil] Deleted value or nil
      def delete(key)
        @mutex.synchronize do
          @access_order.delete(key)
          @timestamps.delete(key)
          @cache.delete(key)
        end
      end

      # Clear all entries
      def clear
        @mutex.synchronize do
          @cache.clear
          @access_order.clear
          @timestamps.clear
        end
      end

      # Get number of entries in cache
      # @return [Integer] Cache size
      def size
        @mutex.synchronize { @cache.size }
      end

      # Check if cache is empty
      # @return [Boolean]
      def empty?
        @mutex.synchronize { @cache.empty? }
      end

      # Check if key exists in cache
      # @param key [Object] Cache key
      # @return [Boolean]
      def key?(key)
        @mutex.synchronize do
          cleanup_expired
          @cache.key?(key)
        end
      end

      # Get all keys in cache
      # @return [Array] Cache keys
      def keys
        @mutex.synchronize do
          cleanup_expired
          @cache.keys
        end
      end

      # Get cache statistics
      # @return [Hash] Statistics
      def stats
        @mutex.synchronize do
          cleanup_expired
          {
            size: @cache.size,
            max_size: @max_size,
            ttl: @ttl,
            utilization: (@cache.size.to_f / @max_size * 100).round(2)
          }
        end
      end

      private

      # Remove expired entries based on TTL
      def cleanup_expired
        now = Time.now
        expired_keys = @timestamps.select { |_k, t| now - t > @ttl }.keys

        expired_keys.each do |key|
          @access_order.delete(key)
          @timestamps.delete(key)
          @cache.delete(key)
        end
      end

      # Evict least recently used entry
      def evict_oldest
        return if @access_order.empty?

        oldest_key = @access_order.shift
        @cache.delete(oldest_key)
        @timestamps.delete(oldest_key)
      end
    end
  end
end
