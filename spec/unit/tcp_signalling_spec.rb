# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Takagi TCP signalling dispatch' do
  def signaling
    Takagi::CoAP::Registries::Signaling
  end

  def build_frame(code:, token: ''.b, options: {})
    Takagi::Message::Outbound.new(
      code: code,
      payload: '',
      token: token.b,
      message_id: 0,
      type: 0,
      options: options,
      transport: :tcp
    ).to_bytes(transport: :tcp)
  end

  def read_frame(sock, timeout: 2)
    return nil unless sock.wait_readable(timeout)

    Takagi::Network::Framing::Tcp.read_from_socket(sock)
  end

  def parse(raw)
    return nil unless raw

    Takagi::Message::Inbound.new(raw, transport: :tcp)
  end

  def eof_within?(sock, timeout: 2)
    return false unless sock.wait_readable(timeout)

    chunk = sock.read(1)
    chunk.nil? || chunk.empty?
  end

  def send_control_ping(sock)
    sock.write(build_frame(code: signaling::PING, token: 'ctl'))

    parse(read_frame(sock, timeout: 3))
  end

  before do
    @port = find_free_port
    @server = Takagi::Base.spawn!(port: @port, protocols: [:tcp])
    @sock = TCPSocket.new('127.0.0.1', @port)
    @csm_raw = read_frame(@sock, timeout: 3)
  end

  after do
    @sock&.close unless @sock&.closed?
    @server&.shutdown!
  end

  it 'writes its CSM 7.01 as the first frame, advertising only Max-Message-Size' do
    csm = parse(@csm_raw)

    expect(csm.code).to eq(signaling::CSM)
    expect(csm.token).to eq(''.b)
    expect(csm.options.keys).to eq([2])
    max_message_size = csm.option(2).bytes.reduce(0) { |acc, byte| (acc << 8) | byte }
    expect(max_message_size).to eq(8_388_864)
    expect(csm.options.key?(4)).to be(false)
  end

  it 'ignores a peer CSM and never sends a second CSM' do
    @sock.write(build_frame(code: signaling::CSM, options: { 2 => [8_388_864] }))

    expect(read_frame(@sock)).to be_nil
    expect(send_control_ping(@sock).code).to eq(signaling::PONG)
  end

  it 'sends no further CSM once the connection is serving requests' do
    request = Takagi::Message::Outbound.new(
      code: Takagi::CoAP::Registries::Method::GET,
      payload: nil,
      token: '12345678',
      options: { 11 => ['ping'] },
      transport: :tcp
    )
    @sock.write(request.to_bytes(transport: :tcp))

    raw = read_frame(@sock, timeout: 5)

    expect(signaling.signaling?(raw.getbyte(1))).to be(false)
    expect(parse(raw).payload).to include('Pong')
  end

  it 'ignores an empty frame (Code 0.00) without replying' do
    @sock.write(build_frame(code: Takagi::CoAP::Registries::Method::EMPTY))

    expect(read_frame(@sock)).to be_nil
    expect(send_control_ping(@sock).code).to eq(signaling::PONG)
  end

  it 'ignores an unsolicited Pong without replying' do
    @sock.write(build_frame(code: signaling::PONG, token: 'tk'))

    expect(read_frame(@sock)).to be_nil
    expect(send_control_ping(@sock).code).to eq(signaling::PONG)
  end

  it 'never routes an unassigned signalling code (7.06) as a request' do
    @sock.write(build_frame(code: 230, token: 'tk'))

    expect(read_frame(@sock)).to be_nil
    expect(send_control_ping(@sock).code).to eq(signaling::PONG)
  end

  it 'answers a Ping with a Pong carrying the identical token' do
    @sock.write(build_frame(code: signaling::PING, token: 'tk'))

    pong = parse(read_frame(@sock, timeout: 3))

    expect(pong.code).to eq(signaling::PONG)
    expect(pong.token).to eq('tk')
  end

  it 'answers a Ping carrying Custody immediately, without Custody in the Pong' do
    @sock.write(build_frame(code: signaling::PING, token: 'ab', options: { 2 => [''] }))

    pong = parse(read_frame(@sock, timeout: 3))

    expect(pong.code).to eq(signaling::PONG)
    expect(pong.token).to eq('ab')
    expect(pong.options.key?(2)).to be(false)
  end

  it 'aborts the connection after a Ping carrying an unknown critical signalling option' do
    @sock.write(build_frame(code: signaling::PING, token: 'zz', options: { 1 => [''] }))

    abort_raw = read_frame(@sock, timeout: 3)

    expect(abort_raw&.getbyte(1)).to eq(0xE5)
    expect(parse(abort_raw).code).to eq(signaling::ABORT)
    expect(eof_within?(@sock)).to be(true)
  end

  it 'aborts the connection after a CSM carrying an unknown critical signalling option' do
    @sock.write(build_frame(code: signaling::CSM, options: { 1 => [''] }))

    abort_raw = read_frame(@sock, timeout: 3)

    expect(abort_raw&.getbyte(1)).to eq(0xE5)
    expect(parse(abort_raw).code).to eq(signaling::ABORT)
    expect(eof_within?(@sock)).to be(true)
  end

  it 'aborts the connection after an unassigned signalling code carrying an unknown critical option' do
    @sock.write(build_frame(code: 230, options: { 1 => [''] }))

    abort_raw = read_frame(@sock, timeout: 3)

    expect(abort_raw&.getbyte(1)).to eq(0xE5)
    expect(parse(abort_raw).code).to eq(signaling::ABORT)
    expect(eof_within?(@sock)).to be(true)
  end

  it 'aborts the connection after a Pong carrying an unknown critical signalling option' do
    @sock.write(build_frame(code: signaling::PONG, token: 'tk', options: { 1 => [''] }))

    abort_raw = read_frame(@sock, timeout: 3)

    expect(abort_raw&.getbyte(1)).to eq(0xE5)
    expect(parse(abort_raw).code).to eq(signaling::ABORT)
    expect(eof_within?(@sock)).to be(true)
  end

  it 'aborts the connection after a Release carrying an unknown critical signalling option' do
    @sock.write(build_frame(code: signaling::RELEASE, options: { 1 => [''] }))

    abort_raw = read_frame(@sock, timeout: 3)

    expect(abort_raw&.getbyte(1)).to eq(0xE5)
    expect(parse(abort_raw).code).to eq(signaling::ABORT)
    expect(eof_within?(@sock)).to be(true)
  end

  it 'aborts the connection when only one of several signalling options is odd' do
    @sock.write(build_frame(code: signaling::CSM, options: { 2 => [8_388_864], 1 => [''] }))

    abort_raw = read_frame(@sock, timeout: 3)

    expect(abort_raw&.getbyte(1)).to eq(0xE5)
    expect(parse(abort_raw).code).to eq(signaling::ABORT)
    expect(eof_within?(@sock)).to be(true)
  end

  it 'still ignores a CSM carrying only even signalling options' do
    @sock.write(build_frame(code: signaling::CSM, options: { 2 => [8_388_864] }))

    expect(read_frame(@sock)).to be_nil
    expect(send_control_ping(@sock).code).to eq(signaling::PONG)
  end

  it 'still ignores a Pong carrying only even signalling options' do
    @sock.write(build_frame(code: signaling::PONG, token: 'tk', options: { 2 => [''] }))

    expect(read_frame(@sock)).to be_nil
    expect(send_control_ping(@sock).code).to eq(signaling::PONG)
  end

  it 'does not abort a regular request carrying an odd option number' do
    request = Takagi::Message::Outbound.new(
      code: Takagi::CoAP::Registries::Method::GET,
      payload: nil,
      token: '12345678',
      options: { 11 => ['ping'] },
      transport: :tcp
    )
    @sock.write(request.to_bytes(transport: :tcp))

    raw = read_frame(@sock, timeout: 5)

    expect(signaling.signaling?(raw.getbyte(1))).to be(false)
    expect(parse(raw).payload).to include('Pong')
    expect(send_control_ping(@sock).code).to eq(signaling::PONG)
  end
end
