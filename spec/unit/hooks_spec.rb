# frozen_string_literal: true

require 'takagi/hooks'

RSpec.describe Takagi::Hooks do
  it 'delivers payloads to subscribers (via EventBus bridge)' do
    payloads = []
    handler = described_class.subscribe(:test_event) { |payload| payloads << payload[:value] }

    described_class.emit(:test_event, value: 42)

    expect(payloads).to eq([42])

    described_class.unsubscribe(:test_event, handler)
  end

  it 'swallows subscriber errors without raising' do
    described_class.subscribe(:error_event) { raise 'boom' }

    expect { described_class.emit(:error_event, value: 1) }.not_to raise_error
  end

  it 'exposes #on as an alias of #subscribe' do
    payloads = []
    handler = described_class.on(:alias_event) { |payload| payloads << payload[:value] }

    described_class.emit(:alias_event, value: 7)

    expect(payloads).to eq([7])

    described_class.unsubscribe(:alias_event, handler)
  end
end
