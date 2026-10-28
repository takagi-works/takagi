# frozen_string_literal: true

RSpec.describe Takagi::ObserveRegistry do
  before { described_class.entries.clear }

  it 'registers and unregisters subscribers by token' do
    described_class.subscribe('/foo', endpoint: '127.0.0.1:5683', token: 'abc')
    expect(described_class.entries['/foo']).to have_key(['127.0.0.1:5683', 'abc'])

    described_class.unsubscribe('/foo', 'abc')
    expect(described_class.entries['/foo']).to be_nil
  end

  it 'derives the endpoint from address and port when none is given' do
    described_class.subscribe('/foo', address: '127.0.0.1', port: 5683, token: 'abc')
    expect(described_class.entries['/foo']).to have_key(['127.0.0.1:5683', 'abc'])
  end

  it 'notifies subscribers' do
    described_class.subscribe('/bar', endpoint: '127.0.0.1:5683', token: 'abc')

    sender_double = instance_double(Takagi::Observer::Sender)
    allow(sender_double).to receive(:send_packet).and_return(
      instance_double(Takagi::Message::Outbound, message_id: 1)
    )
    allow(described_class).to receive(:sender).and_return(sender_double)

    described_class.notify('/bar', 42)

    expect(sender_double).to have_received(:send_packet) do |entry, value, code:, observe:|
      expect(entry[:endpoint]).to eq('127.0.0.1:5683')
      expect(value).to eq(42)
      expect(code).to eq('2.05 Content')
    end
  end

  describe 'entries keyed by endpoint and token' do
    it 'updates one entry on a repeat registration for the same endpoint and token' do
      described_class.subscribe('/t', endpoint: '127.0.0.1:5683', token: 'abc', content_format: 50)
      described_class.subscribe('/t', endpoint: '127.0.0.1:5683', token: 'abc', content_format: 60)

      entries = described_class.entries['/t']
      expect(entries.size).to eq(1)
      expect(entries[['127.0.0.1:5683', 'abc']][:content_format]).to eq(60)
    end

    it 'keeps two peers that share a token and path separate' do
      described_class.subscribe('/t', endpoint: '127.0.0.1:5683', token: 'abc')
      described_class.subscribe('/t', endpoint: '127.0.0.1:5684', token: 'abc')

      expect(described_class.entries['/t'].size).to eq(2)
    end

    it 'removes only the entry of the endpoint that deregisters' do
      described_class.subscribe('/t', endpoint: '127.0.0.1:5683', token: 'abc')
      described_class.subscribe('/t', endpoint: '127.0.0.1:5684', token: 'abc')

      described_class.remove('/t', endpoint: '127.0.0.1:5683', token: 'abc')

      expect(described_class.entries['/t'].keys).to eq([['127.0.0.1:5684', 'abc']])
    end

    it 'removes an entry whose last notification carried the Reset\'s message id' do
      described_class.subscribe('/t', endpoint: '127.0.0.1:5683', token: 'abc')
      described_class.entries['/t'][['127.0.0.1:5683', 'abc']][:last_mid] = 7

      expect(described_class.remove_by_message_id('127.0.0.1:5683', 7)).to be(true)
      expect(described_class.entries['/t']).to be_nil
      expect(described_class.remove_by_message_id('127.0.0.1:5683', 7)).to be(false)
    end
  end

  describe 'observation ending' do
    it 'delivers one non-2.xx notification then removes the entry' do
      described_class.subscribe('/t', endpoint: '127.0.0.1:5683', token: 'abc')

      sender_double = instance_double(Takagi::Observer::Sender)
      allow(sender_double).to receive(:send_packet).and_return(
        instance_double(Takagi::Message::Outbound, message_id: 1)
      )
      allow(described_class).to receive(:sender).and_return(sender_double)

      described_class.notify('/t', nil, code: '4.04 Not Found')

      expect(sender_double).to have_received(:send_packet).once do |_entry, _value, code:, observe:|
        expect(code).to eq('4.04 Not Found')
        expect(observe).to be_nil
      end
      expect(described_class.entries).not_to have_key('/t')
    end
  end

  describe '.cleanup_stale_observers' do
    it 'removes inbound observers that exceeded max age' do
      described_class.subscribe('/stale', endpoint: '127.0.0.1:5683', token: 'abc')
      entry = described_class.entries['/stale'][['127.0.0.1:5683', 'abc']]
      entry[:last_notified_at] = Time.now - 120

      cleaned = described_class.cleanup_stale_observers(max_age: 60)

      expect(cleaned).to eq(1)
      expect(described_class.entries['/stale']).to be_nil
    end

    it 'keeps outbound entries regardless of age' do
      described_class.subscribe('/local', endpoint: '127.0.0.1:5683', token: 'abc',
                                          kind: :outbound, handler: proc {})
      entry = described_class.entries['/local'][['127.0.0.1:5683', 'abc']]
      entry[:last_notified_at] = Time.now - 1_000

      cleaned = described_class.cleanup_stale_observers(max_age: 60)

      expect(cleaned).to eq(0)
      expect(described_class.entries['/local']).not_to be_empty
    end

    it 'keeps handler subscriptions regardless of age' do
      described_class.subscribe('/local', endpoint: '127.0.0.1:5683', token: 'abc', handler: proc {})
      entry = described_class.entries['/local'][['127.0.0.1:5683', 'abc']]
      entry[:last_notified_at] = Time.now - 1_000

      cleaned = described_class.cleanup_stale_observers(max_age: 60)

      expect(cleaned).to eq(0)
      expect(described_class.entries['/local']).not_to be_empty
    end
  end
end