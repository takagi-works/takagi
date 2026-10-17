# frozen_string_literal: true

RSpec.describe 'Takagi Multi Protocol Server' do
  def encode_tcp_frame(data)
    return ''.b if data.empty?

    first_byte = data.getbyte(0)
    tkl = first_byte & 0x0F
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

  it 'handles requests over both UDP and TCP' do
    server = Takagi::Base.spawn!(port: 0, protocols: [:udp, :tcp])
    built = server.instance_variable_get(:@servers)
    udp_port = bound_port_of(built.find { |s| s.is_a?(Takagi::Server::Udp) })
    tcp_port = bound_port_of(built.find { |s| s.is_a?(Takagi::Server::Tcp) })

    # Test UDP
    udp_socket = UDPSocket.new
    request = Takagi::Message::Request.new(method: :get, uri: URI('coap://localhost/ping'))
    udp_socket.send(request.to_bytes, 0, '127.0.0.1', udp_port)
    response, = udp_socket.recvfrom(1024)
    inbound_udp = Takagi::Message::Inbound.new(response)
    expect(inbound_udp.payload).to include('Pong')

    # Test TCP
    tcp_client = TCPSocket.new('127.0.0.1', tcp_port)
    request_tcp = Takagi::Message::Outbound.new(
      code: 1,  # GET
      payload: nil,
      token: 'test1234',
      options: {11 => ['ping']},  # Uri-Path
      transport: :tcp
    )
    data = request_tcp.to_bytes(transport: :tcp)
    framed_data = encode_tcp_frame(data)
    tcp_client.write(framed_data)

    tcp_response = read_tcp_message(tcp_client)
    tcp_client.close

    inbound_tcp = Takagi::Message::Inbound.new(tcp_response, transport: :tcp)
    expect(inbound_tcp.payload).to include('Pong')
  ensure
    server.shutdown!
  end
end
