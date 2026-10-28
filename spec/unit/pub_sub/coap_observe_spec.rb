# frozen_string_literal: true

RSpec.describe Takagi::PubSub::CoapObserve do
  it 'derives its capabilities from the underlying CoAP transport declaration (reactor-interactions)' do
    udp = described_class.for(:udp)
    tcp = described_class.for(:tcp)

    expect(udp.capabilities).to include(
      subscription_confirmed: true,
      ordered_notifications: true,
      carries_reset: true,
      pattern_filters: false,
      block_wise: true
    )
    expect(tcp.capabilities).to include(
      subscription_confirmed: false,
      ordered_notifications: true,
      carries_reset: false,
      pattern_filters: false,
      block_wise: false
    )
  end

  it 'declares every capability the vocabulary lists (1.2)' do
    capabilities = described_class.for(:udp).capabilities
    Takagi::PubSub::TransportRegistry::REQUIRED_CAPABILITIES.each do |capability|
      expect(capabilities).to have_key(capability)
    end
  end

  describe '#notification_type' do
    it 'notifies NON by default and CON for a liveness check' do
      expect(described_class.for(:udp).notification_type)
        .to eq(Takagi::CoAP::Registries::MessageType::NON)
      expect(described_class.for(:udp).notification_type(liveness_check: true))
        .to eq(Takagi::CoAP::Registries::MessageType::CON)
    end

    it 'carries no message type over a reliable transport (RFC 8323 §3)' do
      expect(described_class.for(:tcp).notification_type).to be_nil
    end
  end

  it 'keeps the block-wise declaration and the TCP CSM option list in step (8.2)' do
    binding = described_class.for(:tcp)
    expect(binding.capabilities[:block_wise]).to be(false)

    server = Takagi::Server::Tcp.new(port: 0, worker_processes: 1, worker_threads: 1)
    csm = server.send(:build_csm_message)
    options = csm.options

    # RFC 8323 §5.3.7: Block-Wise-Transfer (option 4) must not be advertised when the
    # binding does not offer block-wise (BERT is out of scope over TCP).
    expect(options).not_to have_key(4)
    expect(options).to have_key(2)
  ensure
    server&.shutdown!
  end
end