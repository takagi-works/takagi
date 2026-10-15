# frozen_string_literal: true

RSpec.describe Takagi::Server::Tcp do
  subject(:server) { described_class.new(port: 0, max_connections: 1) }

  after { server.shutdown! }

  it 'enforces the configured connection limit' do
    expect(server.send(:track_connection)).to be(true)
    expect(server.send(:track_connection)).to be(false)

    server.send(:release_connection)
    expect(server.send(:track_connection)).to be(true)
  end

  it 'allows unlimited connections when no limit is configured' do
    unlimited = described_class.new(port: 0)
    5.times { expect(unlimited.send(:track_connection)).to be(true) }
    unlimited.shutdown!
  end
end
