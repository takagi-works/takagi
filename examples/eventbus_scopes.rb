#!/usr/bin/env ruby
# frozen_string_literal: true

# EventBus Scope Demonstration
#
# Shows the three scope levels:
# - :local  - This instance only
# - :cluster - All instances (future)
# - :global - Cluster + external CoAP clients (future)

require_relative '../lib/takagi'

# Alias for convenience
EventBus = Takagi::EventBus

# Note: Logger level already set by Takagi initialization

puts "=" * 60
puts "EventBus Scope Levels Demo"
puts "=" * 60
puts

# ============================================
# Local Scope (Default)
# ============================================

puts "1. LOCAL SCOPE (default)"
puts "   Messages stay on this instance only"
puts

EventBus.consumer('system.startup') do |msg|
  puts "   ✓ Received system.startup: #{msg.body.inspect}"
  puts "     Scope: #{msg.scope}"
end

EventBus.publish('system.startup', { version: '1.0', node: 'instance-a' })
# Default scope: :local
sleep 0.1  # Allow async delivery

puts

# ============================================
# Explicit Local Scope
# ============================================

puts "2. EXPLICIT LOCAL SCOPE"
puts "   Same as default, but explicit"
puts

EventBus.consumer('plugin.loaded') do |msg|
  puts "   ✓ Received plugin.loaded: #{msg.body.inspect}"
  puts "     Scope: #{msg.scope}"
end

EventBus.publish('plugin.loaded', { name: 'auth', version: '2.0' }, scope: :local)
sleep 0.1

puts

# ============================================
# Cluster Scope (Phase 2)
# ============================================

puts "3. CLUSTER SCOPE (future)"
puts "   Will be distributed to all instances in cluster"
puts

EventBus.consumer('cache.invalidate') do |msg|
  puts "   ✓ Received cache.invalidate: #{msg.body.inspect}"
  puts "     Scope: #{msg.scope}"
  puts "     Note: Currently only delivered locally"
  puts "           (cluster distribution in Phase 2)"
end

EventBus.publish('cache.invalidate', { key: 'user:123', reason: 'update' }, scope: :cluster)
sleep 0.1

puts

# ============================================
# Global Scope (Phase 2)
# ============================================

puts "4. GLOBAL SCOPE (future)"
puts "   Delivered to cluster + external CoAP subscribers"
puts

EventBus.consumer('sensor.temperature') do |msg|
  puts "   ✓ Received sensor.temperature: #{msg.body.inspect}"
  puts "     Scope: #{msg.scope}"
  puts "     Note: Will also publish to CoAP observers"
  puts "           (when CoAP server running)"
end

EventBus.publish('sensor.temperature', { value: 25.5, unit: 'C', room: 'room1' }, scope: :global)
sleep 0.1

puts

# ============================================
# Scope Validation
# ============================================

puts "5. SCOPE VALIDATION"
puts "   Invalid scopes normalize to :local"
puts

EventBus.consumer('test.invalid') do |msg|
  puts "   ✓ Received test.invalid: #{msg.body.inspect}"
  puts "     Scope: #{msg.scope} (normalized from :invalid)"
end

EventBus.publish('test.invalid', { data: 'test' }, scope: :invalid)
sleep 0.1

puts

# ============================================
# Multiple Scopes Example
# ============================================

puts "6. REAL-WORLD SCENARIO"
puts "   Smart factory with different event types"
puts

# Internal system event
EventBus.consumer('system.error') do |msg|
  puts "   ✓ System Error (local): #{msg.body[:error]}"
end
EventBus.publish('system.error', { error: 'Database timeout', severity: 'high' }, scope: :local)
sleep 0.1

# Cluster coordination
EventBus.consumer('cluster.config.reload') do |msg|
  puts "   ✓ Config Reload (cluster): #{msg.body[:section]}"
end
EventBus.publish('cluster.config.reload', { section: 'auth', version: 2 }, scope: :cluster)
sleep 0.1

# Public telemetry
EventBus.consumer('telemetry.requests') do |msg|
  puts "   ✓ Telemetry (global): #{msg.body[:count]} requests"
end
EventBus.publish('telemetry.requests', { count: 1234, period: '1m' }, scope: :global)
sleep 0.1

puts

# ============================================
# Statistics
# ============================================

puts "7. EVENTBUS STATISTICS"
puts

stats = EventBus.stats
puts "   Consumers: #{stats[:consumers]}"
puts "   Addresses: #{stats[:addresses]}"
puts "   Distributed Addresses: #{stats[:distributed_addresses]}"
puts "   Local Addresses: #{stats[:local_addresses]}"

puts
puts "=" * 60
puts "Demo Complete"
puts "=" * 60
puts
puts "Key Takeaways:"
puts "  • :local (default) - Fast in-memory, this instance only"
puts "  • :cluster - Distributed to all instances (Phase 2)"
puts "  • :global - Cluster + external CoAP clients (Phase 2)"
puts "  • Invalid scopes normalize to :local"
puts "  • Backward compatible - existing code uses :local default"
puts

# Cleanup
EventBus.shutdown
