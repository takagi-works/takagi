# frozen_string_literal: true

require 'takagi/hooks'

RSpec.describe Takagi::Hooks do
  it 'delivers payloads to subscribers (via EventBus bridge)' do
    payloads = []
    handler = described_class.subscribe(:test_event) { |payload| payloads << payload[:value] }

    described_class.emit(:test_event, value: 42)
    sleep 0.01 # Allow async EventBus delivery

    expect(payloads).to eq([42])

    described_class.unsubscribe(:test_event, handler)
  end

  it 'swallows subscriber errors without raising' do
    described_class.subscribe(:error_event) { raise 'boom' }

    expect { described_class.emit(:error_event, value: 1) }.not_to raise_error
  end
end
