# frozen_string_literal: true

require 'uri'

RSpec.describe Takagi::Topic do
  let(:observe) { Takagi::CoAP::Registries::Option::OBSERVE }
  let(:content_format) { Takagi::CoAP::Registries::Option::CONTENT_FORMAT }

  before { Takagi::Observer::Registry.entries.clear }

  def request_for(path, observe_value: nil, token: 'tok', transport: :udp,
                  source_endpoint: ['127.0.0.1', 40_000])
    options = observe_value.nil? ? {} : { observe => observe_value }
    raw = Takagi::Message::Request.new(method: :get, uri: URI("coap://x#{path}"),
                                       token: token, options: options).to_bytes
    Takagi::Message::Inbound.new(raw, transport: :udp).tap do |request|
      # The topic reads the transport to decide registration confirmation; the real TCP
      # server frames the request as :tcp, which this unit exercised by overriding it.
      request.instance_variable_set(:@transport, transport)
      request.source_endpoint = source_endpoint
    end
  end

  describe 'current representation' do
    it 'serves the same representation on a stable second read' do
      topic = described_class.new('/t') { 'v' }
      expect(topic.current_value).to eq('v')
      expect(topic.current_value).to eq('v')
    end

    it 'runs the producer once, at declaration: serving does not re-run it' do
      runs = 0
      topic = described_class.new('/t') { runs += 1; 'v' }
      topic.handle_request(request_for('/t'))
      topic.handle_request(request_for('/t'))
      expect(runs).to eq(1)
    end

    it 'answers before any request was served' do
      expect(described_class.new('/t') { 'v' }.current_value).to eq('v')
    end
  end

  describe 'declaring a topic on a router' do
    it 'refuses a duplicate declaration of the same path' do
      router = Takagi::Router.new
      router.topic('/t') { 'a' }

      expect { router.topic('/t') { 'b' } }
        .to raise_error(Takagi::Topic::DuplicateTopicError, %r{/t})
      expect(router.topic_for('/t').current_value).to eq('a')
    end
  end

  describe '#publish' do
    it 'makes a different representation the one served to later reads and notifies' do
      topic = described_class.new('/t') { 'v0' }
      notified = []
      Takagi::Observer::Registry.subscribe('/t', endpoint: '127.0.0.1:1', token: 'x',
                                                 kind: :outbound,
                                                 handler: proc { |v, _| notified << v })
      expect(topic.publish('v1')).to be(true)
      expect(topic.current_value).to eq('v1')
      expect(notified).to eq(['v1'])
    end

    it 'publishing an equal representation produces no notification' do
      topic = described_class.new('/t') { 'v' }
      notified = 0
      Takagi::Observer::Registry.subscribe('/t', endpoint: '127.0.0.1:1', token: 'x',
                                                 kind: :outbound,
                                                 handler: proc { notified += 1 })
      expect(topic.publish('v')).to be(false)
      expect(notified).to eq(0)
    end
  end

  describe '#handle_request' do
    it 'answers a plain GET with the current representation without registering' do
      topic = described_class.new('/t') { 'v' }
      response = topic.handle_request(request_for('/t'))
      expect(response.code).to eq(Takagi::CoAP::Registries::Response::CONTENT)
      expect(response.payload).to eq('v')
      expect(response.options).not_to have_key(observe)
      expect(Takagi::Observer::Registry.entries).not_to have_key('/t')
    end

    it 'registers an inbound observer on GET with Observe: 0 and returns option 6' do
      topic = described_class.new('/t') { 'v' }
      response = topic.handle_request(request_for('/t', observe_value: 0,
                                                      token: 'tok', source_endpoint: ['127.0.0.1', 40_000]))
      expect(response.options).to have_key(observe)
      expect(response.options).to have_key(content_format)
      entry = Takagi::Observer::Registry.entries['/t']
      expect(entry).to have_key(['127.0.0.1:40000', 'tok'])
      expect(entry[['127.0.0.1:40000', 'tok']]).to include(kind: :inbound)
    end

    it 'refuses a registration the transport cannot confirm: no option 6, no entry' do
      topic = described_class.new('/t') { 'v' }
      response = topic.handle_request(request_for('/t', observe_value: 0, transport: :tcp))
      expect(response.options).not_to have_key(observe)
      expect(Takagi::Observer::Registry.entries).not_to have_key('/t')
    end

    it 'deregisters with the observation token and Observe: 1, answered as a normal GET' do
      topic = described_class.new('/t') { 'v' }
      topic.handle_request(request_for('/t', observe_value: 0, token: 'tok',
                                             source_endpoint: ['127.0.0.1', 40_000]))
      response = topic.handle_request(request_for('/t', observe_value: 1, token: 'tok',
                                                        source_endpoint: ['127.0.0.1', 40_000]))
      expect(response.options).not_to have_key(observe)
      expect(Takagi::Observer::Registry.entries['/t']).to be_nil
    end

    it 'does not remove another endpoint\'s entry on deregistration' do
      topic = described_class.new('/t') { 'v' }
      topic.handle_request(request_for('/t', observe_value: 0, token: 'tok',
                                             source_endpoint: ['127.0.0.1', 40_000]))
      response = topic.handle_request(request_for('/t', observe_value: 1, token: 'tok',
                                                        source_endpoint: ['10.0.0.1', 50_000]))
      expect(response.options).not_to have_key(observe)
      expect(Takagi::Observer::Registry.entries['/t']).to have_key(['127.0.0.1:40000', 'tok'])
    end
  end

  describe '#delete' do
    it 'notifies each observer once with the condition code and removes the entries' do
      topic = described_class.new('/t') { 'v' }
      topic.handle_request(request_for('/t', observe_value: 0, token: 'tok',
                                             source_endpoint: ['127.0.0.1', 40_000]))
      topic.handle_request(request_for('/t', observe_value: 0, token: 'tok2',
                                             source_endpoint: ['127.0.0.1', 40_001]))

      sender = instance_double(Takagi::Observer::Sender)
      allow(sender).to receive(:send_packet) do |entry, value, code:, observe:|
        expect(code).to eq('4.04 Not Found')
        expect(observe).to be_nil
        instance_double(Takagi::Message::Outbound, message_id: 1)
      end
      allow(Takagi::Observer::Registry).to receive(:sender).and_return(sender)

      topic.delete

      expect(sender).to have_received(:send_packet).twice
      expect(Takagi::Observer::Registry.entries).not_to have_key('/t')
      expect(topic.deleted?).to be(true)
    end
  end
end