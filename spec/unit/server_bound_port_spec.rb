# frozen_string_literal: true

# Row 10 of .omo/plans/coap-proxy.md, GUARD half: both transports already report the port their
# own socket bound and update `@port` after binding (`udp.rb:44-48`, `tcp.rb:36-41`), so these
# examples pass on the untouched tree and pin the infrastructure the proxy entry point leans on
# instead of re-implementing.
RSpec.describe 'the servers bound port reader (plan row 10 guard)' do
  it 'reports the port its own socket bound instead of the requested 0 (GUARD)' do
    udp = Takagi::Server::Udp.new(port: 0)
    tcp = Takagi::Server::Tcp.new(port: 0)

    expect(udp.bound_port).to be_positive
    expect(tcp.bound_port).to be_positive

    # The oracle is the socket itself, read here without the spec helper so the expectation cannot
    # pass on the reader agreeing with itself.
    expect(udp.bound_port).to eq(udp.instance_variable_get(:@socket).addr[1])
    expect(tcp.bound_port).to eq(tcp.instance_variable_get(:@server).addr[1])
    expect(bound_port_of(udp)).to eq(udp.bound_port)
    expect(bound_port_of(tcp)).to eq(tcp.bound_port)
  ensure
    udp&.shutdown!
    tcp&.shutdown!
  end

  it 'gives two instances of the same transport two different ports (GUARD)' do
    udp_first = Takagi::Server::Udp.new(port: 0)
    udp_second = Takagi::Server::Udp.new(port: 0)
    tcp_first = Takagi::Server::Tcp.new(port: 0)
    tcp_second = Takagi::Server::Tcp.new(port: 0)

    ports = [udp_first, udp_second, tcp_first, tcp_second].map(&:bound_port)
    expect(ports).to all(be_positive)
    expect(ports.uniq.size).to eq(4)
  ensure
    [udp_first, udp_second, tcp_first, tcp_second].each { |server| server&.shutdown! }
  end
end
