# frozen_string_literal: true

RSpec.describe Takagi::PubSub::TransportRegistry do
  let(:capabilities) do
    {
      subscription_confirmed: true,
      ordered_notifications: true,
      carries_reset: true,
      pattern_filters: false,
      max_notification_size: 65_535
    }
  end
  let(:transport) { instance_double('transport', capabilities: capabilities) }

  before { described_class.reset! }
  after { described_class.register_defaults }

  it 'registers a transport by name and resolves it by name' do
    described_class.register(:sensors, transport)
    expect(described_class.resolve(:sensors)).to be(transport)
    expect(described_class.registered?(:sensors)).to be(true)
  end

  it 'returns the declared value for every capability listed' do
    described_class.register(:sensors, transport)
    resolved = described_class.resolve(:sensors)
    described_class::REQUIRED_CAPABILITIES.each do |capability|
      expect(resolved.capabilities).to have_key(capability)
    end
    expect(resolved.capabilities[:max_notification_size]).to eq(65_535)
  end

  it 'refuses a duplicate name, keeping the earlier transport' do
    later = instance_double('later transport', capabilities: capabilities)
    described_class.register(:sensors, transport)
    expect { described_class.register(:sensors, later) }
      .to raise_error(described_class::DuplicateNameError, /sensors/)
    expect(described_class.resolve(:sensors)).to be(transport)
  end

  it 'refuses a transport that declares no capabilities' do
    empty = instance_double('empty transport', capabilities: {})
    expect { described_class.register(:empty, empty) }
      .to raise_error(described_class::MissingCapabilitiesError, /empty/)
  end

  it 'refuses an entry that does not declare capabilities at all' do
    bare = instance_double('bare transport')
    expect { described_class.register(:bare, bare) }
      .to raise_error(described_class::MissingCapabilitiesError, /bare/)
  end

  it 'raises when an unregistered name is resolved' do
    expect { described_class.resolve(:nope) }
      .to raise_error(described_class::TransportNotFoundError, /nope/)
  end

  context 'default registration' do
    after { described_class.register_defaults }

    it 'ships coap_observe as the default registered transport' do
      described_class.register_defaults
      expect(described_class.registered?(:coap_observe)).to be(true)
      expect(described_class.resolve(:coap_observe)).to be_a(Takagi::PubSub::CoapObserve)
    end
  end
end