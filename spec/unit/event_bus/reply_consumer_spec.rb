# frozen_string_literal: true

RSpec.describe 'EventBus reply consumers' do
  it 'removes the temporary reply consumer once its handler runs' do
    Takagi::EventBus.send('query.x', {}) { |_reply| }

    handlers = Takagi::EventBus.instance_variable_get(:@handlers)
    reply_address = handlers.keys.find { |address| address.to_s.start_with?('reply.') }
    handler = handlers[reply_address].first
    consumers = Takagi::EventBus.instance_variable_get(:@consumers)

    expect(consumers.values).to include(handler)

    handler.call(Takagi::EventBus::Message.new(reply_address, { ok: true }))

    expect(Takagi::EventBus.instance_variable_get(:@consumers).values).not_to include(handler)
  end
end
