# frozen_string_literal: true

require 'timeout'

RSpec.describe Takagi::PubSub::Dispatch do
  let(:subscription_capabilities) do
    {
      subscription_confirmed: true,
      ordered_notifications: true,
      carries_reset: true,
      pattern_filters: false,
      max_notification_size: 65_535
    }
  end

  before { Takagi::PubSub::TransportRegistry.reset! }
  after { Takagi::PubSub::TransportRegistry.register_defaults }

  def registering_transport(implementation)
    capabilities = subscription_capabilities
    Class.new do
      define_method(:capabilities) { capabilities }
      define_method(:subscribe) { |options:| implementation.call(options) }
    end.new
  end

  it 'refuses a pattern filter on a transport that declares no pattern support, naming the capability (reactor-interactions)' do
    transport = registering_transport(proc { |_options| :accepted })
    Takagi::PubSub::TransportRegistry.register(:dispatch_spec, transport)

    expect do
      described_class.dispatch(:dispatch_spec, :subscribe, options: { pattern: 'sensor.*' })
    end.to raise_error(described_class::UnsupportedCapabilityError, /pattern_filters/)

    expect do
      Takagi::PubSub.validate_request!(:dispatch_spec, transport, :subscribe, options: { wildcard: 'sensor.*' })
    end.to raise_error(described_class::UnsupportedCapabilityError, /pattern_filters/)
  end

  it 'refuses a notification bound beyond a transport\'s declared maximum size, naming the capability' do
    transport = registering_transport(proc { |_options| :accepted })
    Takagi::PubSub::TransportRegistry.register(:dispatch_spec, transport)

    expect do
      described_class.dispatch(:dispatch_spec, :publish, options: { max_notification_size: 100_000 })
    end.to raise_error(described_class::UnsupportedCapabilityError, /max_notification_size/)
  end

  it 'accepts a request using only declared capabilities and dispatches it to the transport (reactor-interactions)' do
    seen = Queue.new
    transport = registering_transport(proc { |options| seen << options; :delivered })
    Takagi::PubSub::TransportRegistry.register(:dispatch_spec, transport)

    result = described_class.dispatch(:dispatch_spec, :subscribe, options: { max_notification_size: 1024 })

    expect(result).to eq(:delivered)
    expect(Timeout.timeout(5) { seen.pop }).to eq(max_notification_size: 1024)
  end

  it 'resolves alias spellings through the verb table on dispatch' do
    transport = registering_transport(proc { |_options| :subscribed })
    Takagi::PubSub::TransportRegistry.register(:dispatch_spec, transport)

    expect(described_class.dispatch(:dispatch_spec, :on)).to eq(:subscribed)
  end

  it 'refuses an unknown verb on dispatch' do
    transport = registering_transport(proc { |_options| :accepted })
    Takagi::PubSub::TransportRegistry.register(:dispatch_spec, transport)

    expect do
      described_class.dispatch(:dispatch_spec, :teleport)
    end.to raise_error(Takagi::PubSub::ReactorInteraction::UnknownNameError, /teleport/)
  end

  it 'refuses a transport that does not implement the requested verb' do
    transport = instance_double('transport', capabilities: subscription_capabilities)
    Takagi::PubSub::TransportRegistry.register(:dispatch_spec, transport)

    expect do
      described_class.dispatch(:dispatch_spec, :subscribe, options: {})
    end.to raise_error(described_class::UnsupportedVerbError, /dispatch_spec.*subscribe/)
  end
end