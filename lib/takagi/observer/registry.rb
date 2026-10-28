# frozen_string_literal: true

require_relative '../hooks'

module Takagi
  module Observer
    # Keeps track of observers and broadcasts state changes to interested parties.
    #
    # Entries are keyed by client endpoint AND token (RFC 7641 §4.1) and carry a kind:
    # `:inbound` for peers observing us, `:outbound` for observations we started (identifiable
    # by their local `:handler`). A repeat registration for the same endpoint and token
    # UPDATES the existing entry instead of adding a second one, and two peers that happen to
    # share a token on the same path stay separate. Outbound entries are never expired by
    # age; inbound entries are, so a peer that forgets cannot leak forever.
    #
    # This registry intentionally does NOT use Registry::Base because:
    # 1. It stores a map of subscriptions per path (not simple key-value pairs)
    # 2. It has complex domain logic (delta checking, notifications, cleanup)
    # 3. It needs fine-grained mutex control for notify operations
    # 4. The API is fundamentally different (subscribe/notify vs register/get)
    #
    # This is already thread-safe with its own @mutex implementation.
    class Registry
      @entries = {}
      @mutex = Mutex.new
      @cleanup = nil
      @cleanup_mutex = Mutex.new

      class << self
        attr_reader :entries

        # Legacy alias for the raw entries store (path => { [endpoint, token] => entry }),
        # kept for existing callers that clear or inspect it directly.
        alias subscriptions entries

        # Registers one entry per (endpoint, token).
        #
        # @param path [String] the observed resource path
        # @param subscriber [Hash] with `:endpoint` (or `:address`/`:port` to derive it),
        #   `:token`, and optionally `:kind` (`:inbound`/`:outbound`), `:handler`,
        #   `:content_format`, `:transport`, `:created_at`
        # @return [Hash] the stored entry
        def subscribe(path, subscriber)
          entry = normalize_entry(subscriber.dup)

          key = [entry[:endpoint], token_of(entry)]

          @mutex.synchronize do
            @entries[path] ||= {}
            @entries[path][key] = entry
          end

          Takagi::Hooks.emit(:observe_subscribed, path: path, subscription: entry)

          entry
        end

        # Removes every entry of a path whose token matches; the wire removes by endpoint
        # and token with {#remove}.
        #
        # @param path [String]
        # @param token [String]
        # @return [void]
        def unsubscribe(path, token)
          token_b = token.to_s.b

          @mutex.synchronize do
            list = @entries[path]
            next unless list

            list.delete_if { |(_endpoint, entry_token), _entry| entry_token == token_b }
            @entries.delete(path) if list.empty?
          end

          Takagi::Hooks.emit(:observe_unsubscribed, path: path, token: token)
        end

        # Removes the single entry keyed by endpoint and token.
        #
        # @param path [String]
        # @param endpoint [String]
        # @param token [String]
        # @return [void]
        def remove(path, endpoint:, token:)
          key = [endpoint, token.to_s.b]

          @mutex.synchronize do
            list = @entries[path]
            next unless list

            list.delete(key)
            @entries.delete(path) if list.empty?
          end

          Takagi::Hooks.emit(:observe_unsubscribed, path: path, token: token)
        end

        # Removes the entry a Reset answers: the one whose last notification carried the
        # Reset's message id (RFC 7641 §4.5). Returns true when an entry was removed.
        #
        # @param endpoint [String]
        # @param message_id [Integer]
        # @return [Boolean]
        def remove_by_message_id(endpoint, message_id)
          removed = false

          @mutex.synchronize do
            @entries.each do |path, list|
              key = list.keys.find do |(entry_endpoint, token)|
                entry_endpoint == endpoint && list[[entry_endpoint, token]][:last_mid] == message_id
              end
              next unless key

              list.delete(key)
              @entries.delete(path) if list.empty?
              removed = true
            end
          end

          removed
        end

        # Notifies every observer of a path with the new value.
        #
        # A `2.xx` code carries the Observe option when `observe:` is given. A non-`2.xx`
        # code ends the observation (RFC 7641 §4.2): delivered once with no Observe option,
        # then the entry is removed so no further notification is sent.
        #
        # @param path [String]
        # @param new_value [Object]
        # @param observe [Integer, nil] sequence value for the Observe option
        # @param code [String] the CoAP response code of the notification
        # @return [void]
        def notify(path, new_value, observe: nil, code: '2.05 Content')
          snapshot = @mutex.synchronize { @entries[path]&.dup }
          return unless snapshot

          snapshot.each do |(endpoint, token), subscription|
            deliver_notification(subscription, path, new_value, observe: observe, code: code)
            subscription[:last_notified_at] = Time.now

            remove(path, endpoint: endpoint, token: token) unless code.to_s.start_with?('2.')
          end
        end

        def sender
          @sender ||= Takagi::Observer::Sender.new
        end

        def subscription_paths
          @mutex.synchronize { @entries.keys }
        end

        def cleanup_stale_observers(max_age:, now: Time.now)
          cutoff = now - max_age
          cleaned = 0

          @mutex.synchronize do
            @entries.each do |path, list|
              list.delete_if do |(_endpoint, _token), subscription|
                stale = stale_subscription?(subscription, cutoff)
                cleaned += 1 if stale
                stale
              end
              @entries.delete(path) if list.empty?
            end
          end

          cleaned
        end

        # The registry owns the subscriptions the cleaner expires, so it owns the
        # cleaner's thread. `start_cleanup` is idempotent: repeated boot calls
        # construct and start ONE background cleaner, never two threads racing to
        # expire the same subscriptions.
        def start_cleanup
          @cleanup_mutex.synchronize do
            @cleanup ||= Bus::ObserverCleanup.new(
              interval: event_bus_setting(:cleanup_interval, 'EVENTBUS_CLEANUP_INTERVAL', 60),
              max_age: event_bus_setting(:max_observer_age, 'EVENTBUS_MAX_OBSERVER_AGE', 600)
            )
            @cleanup.start
            @cleanup
          end
        end

        private

        # Same precedence the bus used when it owned the cleaner: configuration
        # beats environment beats default. Keeps the cleaner's interval and
        # max-age configurable exactly as before the ownership moved here.
        def event_bus_setting(config_key, env_key, default)
          if defined?(Takagi.config) && Takagi.config.event_bus.respond_to?(config_key)
            Takagi.config.event_bus.public_send(config_key)
          elsif ENV[env_key]
            ENV[env_key].to_i
          else
            default
          end
        end

        def normalize_entry(entry)
          entry[:endpoint] ||= derive_endpoint(entry)
          entry[:kind] ||= entry[:handler] ? :outbound : :inbound
          entry[:created_at] ||= Time.now
          entry
        end

        def derive_endpoint(entry)
          return unless entry[:address] && entry[:port]

          "#{entry[:address]}:#{entry[:port]}"
        end

        def token_of(entry)
          (entry[:token] || '').to_s.b
        end

        def deliver_notification(subscription, path, new_value, observe:, code:)
          if subscription[:handler]
            Takagi.logger.debug "Calling local handler for #{path}"
            subscription[:handler].call(new_value, nil)
          else
            Takagi.logger.debug "Sending packet to #{subscription[:address]}:#{subscription[:port]}"
            message = sender.send_packet(subscription, new_value, observe: observe, code: code)
            subscription[:last_mid] = message.message_id if message
          end
        end

        def stale_subscription?(subscription, cutoff)
          return false if subscription[:kind] == :outbound || subscription[:handler]

          last_activity = subscription[:last_notified_at] || subscription[:created_at]
          return false unless last_activity

          last_activity < cutoff
        end
      end
    end
  end
end
