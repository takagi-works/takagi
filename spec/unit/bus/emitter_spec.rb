# frozen_string_literal: true

require 'spec_helper'
require 'timeout'

RSpec.describe Takagi::Observable::Emitter do
  let(:path) { '/sensor/temp' }
  let(:bus_address) { 'sensor.temp' }
  let(:token) { 'emitter-spec-token' }

  before { @consumer_ids = [] }

  # `on_event` subscribes on the process-default bus and the observer registry is a
  # process-wide singleton, so each example has to give both back what it took.
  after do
    @consumer_ids.each { |id| Takagi.bus.unregister(id) }
    Takagi::Observer::Registry.unsubscribe(path, token)
  end

  def observe
    received = Queue.new
    Takagi::Observer::Registry.subscribe(
      path,
      { token: token, handler: ->(value, _context) { received << value } }
    )
    received
  end

  def subscribe(emitter, &transform)
    id = emitter.on_event(bus_address, &transform)
    @consumer_ids << id
    id
  end

  it 'subscribes locally and forwards a transformed value to an observer' do
    received = observe
    expect(Takagi::EventBus::CoAPBridge).not_to receive(:subscribe_remote)

    subscribe(described_class.new(path)) do |event|
      { temp: event.body[:celsius] * 2, at: event.timestamp }
    end
    Takagi.bus.publish(bus_address, { celsius: 21 })

    value = Timeout.timeout(5) { received.pop }
    expect(value[:temp]).to eq(42)
    expect(value[:at]).to be_a(Time)
  end

  it 'forwards the message body when no transform block is given' do
    received = observe

    subscribe(described_class.new(path))
    Takagi.bus.publish(bus_address, { celsius: 21 })

    expect(Timeout.timeout(5) { received.pop }).to eq({ celsius: 21 })
  end

  it 'hands the transformed value to Observer::Registry.notify for its own path' do
    expect(Takagi::Observer::Registry).to receive(:notify).with(path, { celsius: 21 })

    subscribe(described_class.new(path)) { |event| event.body }
    Takagi.bus.publish(bus_address, { celsius: 21 })
  end

  it 'returns the consumer id and stops forwarding once it is unregistered' do
    received = observe
    emitter = described_class.new(path)

    id = subscribe(emitter) { |event| event.body }
    expect(id).to be_a(String)

    Takagi.bus.publish(bus_address, { celsius: 1 })
    expect(Timeout.timeout(5) { received.pop }).to eq({ celsius: 1 })

    Takagi.bus.unregister(id)
    @consumer_ids.delete(id)
    Takagi.bus.publish(bus_address, { celsius: 2 })

    expect(received).to be_empty
  end

  it 'keeps notify forwarding to the observers of its own path' do
    received = observe

    described_class.new(path).notify({ temp: 25.5 })

    expect(Timeout.timeout(5) { received.pop }).to eq({ temp: 25.5 })
  end
end
