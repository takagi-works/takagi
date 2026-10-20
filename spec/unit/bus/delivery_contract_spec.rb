# frozen_string_literal: true

require 'spec_helper'
require 'timeout'

# The delivery contract of the local bus (row 2 of .omo/plans/local-bus.md):
# `publish` snapshots the matching subscribers under the registry lock, then
# delivers to that snapshot OUTSIDE the lock, synchronously and in registration
# order; a raising subscriber must not stop the rest of the same message and is
# reported through `:bus_subscriber_error`.
RSpec.describe 'Takagi::Bus delivery contract' do
  let(:bus) { Takagi::Bus.new }

  after { bus.shutdown }

  it 'delivers three published messages in order, to subscribers in registration order, with no wait' do
    received = []
    bus.consumer('ordered.event') { |msg| received << [:first, msg.body[:seq]] }
    bus.consumer('ordered.event') { |msg| received << [:second, msg.body[:seq]] }
    bus.consumer('ordered.event') { |msg| received << [:third, msg.body[:seq]] }

    Timeout.timeout(5) do
      (1..3).each { |seq| bus.publish('ordered.event', { seq: seq }) }
    end

    expect(received).to eq([
      [:first, 1], [:second, 1], [:third, 1],
      [:first, 2], [:second, 2], [:third, 2],
      [:first, 3], [:second, 3], [:third, 3]
    ])
    expect(bus.executor).to be_nil
  end

  it 'delivers re-entrantly: publish, subscribe and unsubscribe from inside a delivery' do
    inner = []
    calls = Hash.new(0)
    late_id = nil

    bus.consumer('reentrant.trigger') do |_msg|
      calls[:publisher] += 1
      bus.publish('reentrant.inner', { from: :publisher })
    end

    bus.consumer('reentrant.trigger') do |_msg|
      calls[:subscriber] += 1
      late_id ||= bus.consumer('reentrant.inner') { |msg| inner << msg.body[:from] }
    end

    unsubscriber_id = bus.consumer('reentrant.trigger') do |_msg|
      calls[:unsubscriber] += 1
      bus.unregister(unsubscriber_id)
    end

    Timeout.timeout(5) do
      bus.publish('reentrant.trigger', {})
      bus.publish('reentrant.trigger', {})
    end

    expect(calls).to eq(publisher: 2, subscriber: 2, unsubscriber: 1)
    expect(inner).to eq([:publisher])
  end

  it 'keeps delivering to later subscribers when one raises, and reports it through the hook' do
    received = []
    reported = []
    hook = Takagi::Hooks.subscribe(:bus_subscriber_error) { |payload| reported << payload }

    raising_id = bus.consumer('error.event') { raise 'boom' }
    bus.consumer('error.event') { |msg| received << msg.body[:seq] }

    expect do
      Timeout.timeout(5) { bus.publish('error.event', { seq: 1 }) }
    end.not_to raise_error

    expect(received).to eq([1])
    expect(reported.size).to eq(1)
    expect(reported.first[:address]).to eq('error.event')
    expect(reported.first[:subscriber_id]).to eq(raising_id)
    expect(reported.first[:error]).to be_a(RuntimeError)
    expect(reported.first[:error].message).to eq('boom')
  ensure
    Takagi::Hooks.unsubscribe(:bus_subscriber_error, hook)
  end
end
