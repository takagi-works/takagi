# frozen_string_literal: true

require "rspec"

require "socket"
require_relative "../../lib/takagi"

RSpec.describe "Takagi RFC 7252 Compliance" do
  before(:all) do
    @server = Takagi::Base.spawn!(port: 0)
    @port = bound_port_of(@server)
    @client = UDPSocket.new
    @server_address = ['127.0.0.1', @port]
  end

  after(:all) do
    @server.shutdown!
    @client.close
  end

  # A bare 4-byte CoAP header; +first_byte+ carries version, type and Token Length.
  def coap_header(first_byte, message_id)
    [first_byte, 0x00, (message_id >> 8) & 0xFF, message_id & 0xFF].pack('C*')
  end

  # Ver:1, Type:RST, TokenLen:0, Code:0.00 - the RFC 7252 Reset reply.
  def reset_header(message_id)
    coap_header(0x70, message_id)
  end

  # Sends +bytes+ and returns the first datagram the server sends back within
  # +deadline+ seconds, or nil when the server stays silent.
  def exchange(bytes, deadline: 1.0)
    @client.send(bytes.b, 0, *@server_address)
    return nil unless @client.wait_readable(deadline)

    @client.recvfrom(4096).first
  end

  # Bounded silence assertion: the server must send nothing within +deadline+.
  def expect_silence(bytes, deadline: 0.3)
    reply = exchange(bytes, deadline: deadline)
    expect(reply).to be_nil
  end

  # Drains datagrams already queued on the shared client socket so a silence
  # assertion cannot pass on a stale reply.
  def drain_client
    @client.recvfrom(4096) while @client.wait_readable(0)
  end

  # Control request proving the server still answers after an ignored datagram.
  def expect_server_alive
    response = send_coap_request(:con, :get, '/ping', nil, message_id: rand(0..0xFFFF))
    expect(response).to include('Pong')
  end

  it "handles GET requests correctly" do
    response = send_coap_request(:con, :get, "/ping")
    expect(response).to include("Pong")
  end

  it "handles POST requests correctly" do
    response = send_coap_request(:con, :post, "/echo", '{"message": "Hello"}')
    expect(response).to include("Hello")
  end

  it "piggybacks ACK replies for confirmable requests and echoes the token" do
    token = "\xAA\xBB".b
    message_id = 0x4242

    response = send_coap_request(:con, :get, "/ping", nil, token: token, message_id: message_id)
    parsed = Takagi::Message::Inbound.new(response)

    expect(parsed.type).to eq(2) # ACK
    expect(parsed.token).to eq(token)
    expect(parsed.message_id).to eq(message_id)
    expect(parsed.code).to eq(69) # 2.05 Content
  end

  it "returns NON responses for NON requests" do
    response = send_coap_request(:non, :get, "/ping")
    parsed = Takagi::Message::Inbound.new(response)

    expect(parsed.type).to eq(1) # NON
    expect(parsed.code).to eq(69)
  end

  it "responds with correct error codes for unknown paths" do
    token = "\x10".b
    message_id = 0x5151
    response = send_coap_request(:con, :get, "/nonexistent", nil, token: token, message_id: message_id)
    parsed = Takagi::Message::Inbound.new(response)

    expect(parsed.code).to eq(132) # 4.04 Not Found
    expect(parsed.token).to eq(token)
    expect(parsed.type).to eq(2) # ACK for CON request
    expect(parsed.message_id).to eq(message_id)
  end

  it "uses unique message IDs and detects duplicates" do
    message_id = 1234
    packet = [64, 1, (message_id >> 8) & 0xFF, message_id & 0xFF].pack("C*") + "/ping".bytes.prepend(5).pack("C*")

    @client.send(packet, 0, *@server_address)
    first_response_raw, = @client.recvfrom(1024)

    @client.send(packet, 0, *@server_address) # Send duplicate
    duplicate_response_raw, = @client.recvfrom(1024)

    first = Takagi::Message::Inbound.new(first_response_raw)
    duplicate = Takagi::Message::Inbound.new(duplicate_response_raw)

    expect(duplicate.payload).to eq(first.payload)
    expect(duplicate.code).to eq(first.code) # Server should detect and discard duplicate
  end

  # RFC 7252 §4.2/§4.3: an Empty CON is a ping; the peer answers with Reset,
  # and an Empty message that cannot be parsed that way is rejected with a
  # token-free Reset (never with a piggybacked ACK).
  it 'answers an empty CON with a Reset using the same Message ID' do
    message_id = 0x4A01
    reply = exchange(coap_header(0x40, message_id)) # Ver:1, Type:CON, TokenLen:0, Code:0.00

    expect(reply).not_to be_nil
    header = reply.bytes

    expect((header[0] >> 6) & 0b11).to eq(1)              # CoAP version
    expect((header[0] >> 4) & 0b11).to eq(3)              # RST, not ACK
    expect(header[1]).to eq(0)                            # Code: 0.00 Empty Message
    expect((header[2] << 8) | header[3]).to eq(message_id) # Same message ID
    expect(reply).to eq(reset_header(message_id))
    expect(reply.bytesize).to eq(4)                       # No token, no payload
  end

  it 'rejects an empty CON carrying a trailing byte with a token-free Reset' do
    message_id = 0x4A02
    reply = exchange(coap_header(0x40, message_id) + "\x5A".b)

    expect(reply).to eq(reset_header(message_id))
    expect(reply.bytesize).to eq(4)
    expect(Takagi::Message::Inbound.new(reply).token).to eq(''.b)
  end

  it 'rejects an empty CON carrying a token byte without echoing the token' do
    message_id = 0x4A03
    reply = exchange(coap_header(0x41, message_id) + "\xAA".b) # TokenLen:1

    parsed = Takagi::Message::Inbound.new(reply)

    expect(parsed.type).to eq(3) # RST
    expect(parsed.message_id).to eq(message_id)
    expect(parsed.token).to eq(''.b)
    expect(reply).to eq(reset_header(message_id))
  end

  it 'rejects an empty CON with a reserved Token Length with a token-free Reset' do
    message_id = 0x4A04
    reply = exchange(coap_header(0x49, message_id) + ("\x01".b * 9)) # TokenLen:9 (reserved)

    expect(reply).to eq(reset_header(message_id))
    expect(Takagi::Message::Inbound.new(reply).token).to eq(''.b)
  end

  it 'answers an empty NON with a Reset using the same Message ID' do
    message_id = 0x4A05
    reply = exchange(coap_header(0x50, message_id)) # Ver:1, Type:NON, TokenLen:0, Code:0.00

    expect(reply).to eq(reset_header(message_id))
  end

  it 'does not answer an empty ACK and keeps serving afterwards' do
    drain_client
    message_id = 0x4A06

    expect_silence(coap_header(0x60, message_id)) # Ver:1, Type:ACK, Code:0.00
    expect_server_alive
  end

  it 'does not answer an empty RST and keeps serving afterwards' do
    drain_client
    message_id = 0x4A07

    expect_silence(coap_header(0x70, message_id)) # Ver:1, Type:RST, Code:0.00
    expect_server_alive
  end

  it 'does not answer a datagram with an unknown version and keeps serving afterwards' do
    drain_client
    message_id = 0x4A08

    expect_silence(coap_header(0x80, message_id)) # Ver:2 (unknown), Type:CON
    expect_server_alive
  end

  it 'does not answer a truncated datagram and keeps serving afterwards' do
    drain_client
    message_id = 0x4A09

    expect_silence(coap_header(0x40, message_id)[0, 2]) # header cut short
    expect_server_alive
  end

  it "responds with RST when receiving unexpected NON message" do
    message_id = rand(0..0xFFFF)
    # NON (Type: 1), Code: 0.00 (Empty)
    packet = [0x50, 0x00, (message_id >> 8), message_id & 0xFF].pack("C*")

    @client.send(packet, 0, *@server_address)
    response = @client.recvfrom(1024).first
    header = response.bytes

    version = (header[0] >> 6) & 0b11
    type = (header[0] >> 4) & 0b11

    expect(version).to eq(1)
    expect(type).to eq(3) # RST
    expect(header[1]).to eq(0) # Empty code
    expect((header[2] << 8) | header[3]).to eq(message_id)
  end

  it "handles large payloads with block-wise transfers" do
    client = Takagi::Client.new("coap://127.0.0.1:#{@port}")
    message = 'x' * 4096

    response = client.post('/echo', { message: message })

    expect(response).not_to be_nil
    expect(response.success?).to be(true)
    expect(response.payload).to include(message)
  ensure
    client&.close
  end
end
