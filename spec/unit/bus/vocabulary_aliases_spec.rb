# frozen_string_literal: true

RSpec.describe Takagi::Bus do
  let(:bus) { described_class.new }

  describe 'vocabulary aliases' do
    it 'registers observe and on as subscriptions, resolving to the same verb on both surfaces' do
      received = []

      bus.observe('events.one') { |message| received << message.body }
      bus.on('events.two') { |message| received << message.body }

      bus.publish('events.one', :a)
      bus.publish('events.two', :b)

      expect(received).to eq(%i[a b])

      expect(Takagi::PubSub::ReactorInteraction.resolve(:observe)).to eq(:subscribe)
      expect(Takagi::PubSub::ReactorInteraction.resolve(:on)).to eq(:subscribe)
      expect(Takagi::PubSub::ReactorInteraction.resolve(:consumer)).to eq(:subscribe)
    end

    it 'publishes through notify and emit as the publish verb' do
      received = []
      bus.consumer('events.three') { |message| received << message.body }

      bus.notify('events.three', :n)
      bus.emit('events.three', :e)

      expect(received).to eq(%i[n e])
    end

    it 'unregisters through cancel and unsubscribe' do
      id = bus.consumer('events.four') { |_message| }
      expect(bus.handler_count('events.four')).to eq(1)

      bus.cancel(id)
      expect(bus.handler_count('events.four')).to eq(0)

      second = bus.consumer('events.four') { |_message| }
      bus.unsubscribe(second)
      expect(bus.handler_count('events.four')).to eq(0)
    end

    it 'keeps subscribe as the documented remote subscription entry point' do
      expect(bus.method(:subscribe).original_name).to eq(:subscribe_remote)
    end
  end
end