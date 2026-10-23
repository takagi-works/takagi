# frozen_string_literal: true

require 'spec_helper'
require 'timeout'

RSpec.describe Takagi::Bus do
  let(:buses) { [] }

  after { buses.each(&:shutdown) }

  def new_bus
    described_class.new.tap { |bus| buses << bus }
  end

  it 'keeps subscriptions on the instance instead of the class' do
    first = new_bus
    second = new_bus
    received = Queue.new

    first.consumer('isolated.event') { |msg| received << msg.body[:seq] }

    second.publish('isolated.event', { seq: 1 })
    first.publish('isolated.event', { seq: 2 })

    expect(Timeout.timeout(5) { received.pop }).to eq(2)
    expect(received).to be_empty
    expect(second.instance_variable_get(:@consumers)).to be_empty
    expect(first.instance_variable_get(:@consumers).size).to eq(1)
  end

  it 'round-robins send across the subscribers of one address in registration order' do
    bus = new_bus
    received = { first: Queue.new, second: Queue.new, third: Queue.new }

    bus.consumer('rr.target') { |msg| received[:first] << msg.body[:seq] }
    bus.consumer('rr.target') { |msg| received[:second] << msg.body[:seq] }
    bus.consumer('rr.target') { |msg| received[:third] << msg.body[:seq] }

    (1..3).each { |seq| bus.send('rr.target', { seq: seq }) }

    expect(Timeout.timeout(5) { received[:first].pop }).to eq(1)
    expect(Timeout.timeout(5) { received[:second].pop }).to eq(2)
    expect(Timeout.timeout(5) { received[:third].pop }).to eq(3)

    bus.send('rr.target', { seq: 4 })

    expect(Timeout.timeout(5) { received[:first].pop }).to eq(4)
  end

  it 'matches wildcard subscriptions by address part' do
    bus = new_bus
    star = Queue.new
    middle = Queue.new

    bus.consumer('sensor.*') { |msg| star << msg.address }
    bus.consumer('sensor.*.room1') { |msg| middle << msg.address }

    bus.publish('sensor.temperature', {})
    bus.publish('sensor.temperature.room1', {})

    expect(Timeout.timeout(5) { star.pop }).to eq('sensor.temperature')
    expect(Timeout.timeout(5) { middle.pop }).to eq('sensor.temperature.room1')
    expect(star).to be_empty
  end

  it 'delivers synchronously without building a delivery executor' do
    bus = new_bus
    received = nil

    expect(bus.executor).to be_nil

    bus.consumer('lazy.event') { |msg| received = msg.body }
    bus.publish('lazy.event', { ok: true })

    expect(received).to eq({ ok: true })
    expect(bus.executor).to be_nil
  end

  it 'does not let a new instance inherit the process default subscribers' do
    first = new_bus
    second = new_bus
    received = Queue.new

    first.consumer('instance.only') { |msg| received << msg.body[:seq] }

    second.publish('instance.only', { seq: 1 })
    first.publish('instance.only', { seq: 2 })

    expect(Timeout.timeout(5) { received.pop }).to eq(2)
    expect(received).to be_empty
    expect(second.instance_variable_get(:@consumers)).to be_empty

    default_id = described_class.default.consumer('default.only') { |msg| received << msg.body[:seq] }
    fresh = new_bus

    expect(described_class.default.instance_variable_get(:@consumers)).not_to be_empty
    expect(fresh.instance_variable_get(:@consumers)).to be_empty
  ensure
    described_class.default.unregister(default_id)
  end

  it 'exposes one process default through Takagi.bus' do
    expect(described_class.default).to equal(described_class.default)
    expect(Takagi.bus).to equal(described_class.default)
  end
end
