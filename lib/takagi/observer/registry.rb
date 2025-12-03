# frozen_string_literal: true

require_relative '../hooks'

module Takagi
  module Observer
    # Keeps track of observers and broadcasts state changes to interested parties.
    #
    # NOTE: This registry intentionally does NOT use Registry::Base because:
    # 1. It stores arrays of subscriptions per path (not simple key-value pairs)
    # 2. It has complex domain logic (delta checking, notifications, cleanup)
    # 3. It needs fine-grained mutex control for notify operations
    # 4. The API is fundamentally different (subscribe/notify vs register/get)
    #
    # This is already thread-safe with its own @mutex implementation.
    class Registry
      @subscriptions = {}
      @mutex = Mutex.new

      class << self
        attr_reader :subscriptions

        def subscribe(path, subscriber)
          entry = subscriber.dup
          entry[:created_at] ||= Time.now
          entry[:last_notified_at] ||= nil

          @mutex.synchronize do
            @subscriptions[path] ||= []
            @subscriptions[path] << entry
          end

          Takagi::Hooks.emit(:observe_subscribed, path: path, subscription: entry)

          entry
        end

        def unsubscribe(path, token)
          @mutex.synchronize do
            return unless @subscriptions[path]

            @subscriptions[path].reject! { |s| s[:token] == token }
          end

          Takagi::Hooks.emit(:observe_unsubscribed, path: path, token: token)
        end

        def notify(path, new_value)
          # Get a snapshot of subscribers to avoid holding the lock during notification
          subscribers = @mutex.synchronize { @subscriptions[path]&.dup }
          return unless subscribers

          Takagi.logger.debug "Notify called for: #{path}"
          Takagi.logger.debug "Subscriptions count: #{subscribers.size}"

          Takagi::Hooks.emit(:observe_notify_start, path: path, subscribers: subscribers&.size || 0, value: new_value)

          subscribers.each do |subscription|
            next unless should_notify?(subscription, new_value)

            deliver_notification(subscription, path, new_value)
            update_sequence(subscription, new_value)
            subscription[:last_notified_at] = Time.now
          end

          Takagi::Hooks.emit(:observe_notify_end, path: path, delivered: subscribers&.size || 0, value: new_value)
        end

        def sender
          @sender ||= Takagi::Observer::Sender.new
        end

        def subscription_paths
          @mutex.synchronize { @subscriptions.keys.dup }
        end

        def cleanup_stale_observers(max_age:, now: Time.now)
          cutoff = now - max_age
          cleaned = 0

          @mutex.synchronize do
            @subscriptions.each do |path, subscribers|
              subscribers.reject! do |subscription|
                stale = stale_subscription?(subscription, cutoff)
                cleaned += 1 if stale
                stale
              end
              @subscriptions.delete(path) if subscribers.empty?
            end
          end

          cleaned
        end

        private

        def should_notify?(subscription, new_value)
          return true unless subscription[:delta] && subscription[:last_value]

          delta_exceeded?(subscription[:last_value], new_value, subscription[:delta])
        end

        def delta_exceeded?(last_value, new_value, threshold)
          (last_value - new_value).abs >= threshold
        rescue StandardError
          true
        end

        def deliver_notification(subscription, path, new_value)
          if subscription[:handler]
            Takagi.logger.debug "Calling local handler for #{path}"
            subscription[:handler].call(new_value, nil)
          else
            Takagi.logger.debug "Sending packet to #{subscription[:address]}:#{subscription[:port]}"
            sender.send_packet(subscription, new_value)
          end
        end

        def update_sequence(subscription, new_value)
          subscription[:last_value] = new_value
          subscription[:last_seq] = (subscription[:last_seq] || 0) + 1
        end

        def stale_subscription?(subscription, cutoff)
          return false if subscription[:handler]

          last_activity = subscription[:last_notified_at] || subscription[:created_at]
          return false unless last_activity

          last_activity < cutoff
        end
      end
    end
  end
end
