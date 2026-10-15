# frozen_string_literal: true

RSpec.describe 'Takagi TCP Server' do
  def encode_tcp_frame(data)
    return ''.b if data.empty?

    first_byte = data.getbyte(0)
    tkl = first_byte & 0x0F

    # Current implementation: Length = size of (Options + Payload)
    code_size = 1
    payload_length = [data.bytesize - 1 - code_size - tkl, 0].max

    body = data.byteslice(1, data.bytesize - 1) || ''.b

    if payload_length <= 12
      new_first_byte = (payload_length << 4) | tkl
      [new_first_byte].pack('C') + body
    elsif payload_length <= 268
      new_first_byte = (13 << 4) | tkl
      extension = payload_length - 13
      [new_first_byte, extension].pack('CC') + body
    elsif payload_length <= 65_804
      new_first_byte = (14 << 4) | tkl
      extension = payload_length - 269
      [new_first_byte].pack('C') + [extension].pack('n') + body
    else
      new_first_byte = (15 << 4) | tkl
      extension = payload_length - 65_805
      [new_first_byte].pack('C') + [extension].pack('N') + body
    end
  end

  def read_tcp_message(socket)
    loop do
      return nil unless socket.wait_readable(5)

      raw = Takagi::Network::Framing::Tcp.read_from_socket(socket)
      return nil unless raw
      return raw unless Takagi::CoAP::Registries::Signaling.signaling?(raw.getbyte(1))
    end
  end

  it 'handles GET requests over TCP' do
    port = find_free_port
    server = Takagi::Base.spawn!(port: port, protocols: [:tcp])
    client = TCPSocket.new('127.0.0.1', port)

    # Create TCP-formatted message using Outbound
    request = Takagi::Message::Outbound.new(
      code: 1,  # GET
      payload: nil,
      token: '12345678',
      options: {11 => ['ping']},  # Uri-Path
      transport: :tcp
    )
    data = request.to_bytes(transport: :tcp)
    framed_data = encode_tcp_frame(data)
    client.write(framed_data)

    response = read_tcp_message(client)
    client.close

    inbound = Takagi::Message::Inbound.new(response, transport: :tcp)
    expect(inbound.payload).to include('Pong')
  ensure
    server.shutdown!
  end

  it 'advertises only Max-Message-Size in its CSM, never Block-Wise-Transfer' do
    server = Takagi::Server::Tcp.new(port: 0)
    csm = server.send(:build_csm_message)
    inbound = Takagi::Message::Inbound.new(csm.to_bytes(transport: :tcp), transport: :tcp)

    expect(inbound.option?(2)).to be(true)
    expect(inbound.option(2).bytes).to eq([0x80, 0x01, 0x00])
    expect(inbound.option?(4)).to be(false)
  ensure
    server.instance_variable_get(:@server)&.close
  end
end
