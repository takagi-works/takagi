# frozen_string_literal: true

require "json"

RSpec.describe Takagi::Message do
  describe Takagi::Message::Inbound do
    let(:coap_get_packet) do
      # version=1, type=0, token_length=1, code=1 (GET), message_id=0x1234, token=0xAA
      # option delta=11 (Uri-Path), length=4, value="test"
      # payload="Ping"
      [
        0b01010001, 0x01, 0x12, 0x34, 0xAA,
        0xB4, "t".ord, "e".ord, "s".ord, "t".ord,
        0xFF, "P".ord, "i".ord, "n".ord, "g".ord
      ].pack("C*")
    end

    it "parses a CoAP GET request with payload and Uri-Path" do
      parsed = Takagi::Message::Inbound.new(coap_get_packet)

      expect(parsed.method).to eq("GET")
      expect(parsed.payload).to eq("Ping")
      expect(parsed.uri.to_s).to eq("coap://localhost/test")
    end

    it "parses empty payload correctly" do
      empty_payload_packet = [
        0b01010001, 0x01, 0x12, 0x34, 0xAA,
        0xB4, "t".ord, "e".ord, "s".ord, "t".ord
      ].pack("C*")

      parsed = Takagi::Message::Inbound.new(empty_payload_packet)
      expect(parsed.payload).to be_nil
    end

    it "keeps the payload intact when a header byte is 0xFF" do
      packet = [0b01010001, 0x45, 0x12, 0xFF, 0xAA] +
               [0x44, 0x00, 0xFF, 0x00, 0x00] +
               [0xFF] + '{"blob":"x"}'.bytes

      parsed = Takagi::Message::Inbound.new(packet.pack("C*"))

      expect(parsed.payload).to eq('{"blob":"x"}')
    end

    it "keeps the payload intact when an option value is 0xFF" do
      packet = [0b01010001, 0x45, 0x12, 0x34, 0xAA] +
               [0x44, 0x00, 0xFF, 0x00, 0x00] +
               [0xFF] + '{"blob":"x"}'.bytes

      parsed = Takagi::Message::Inbound.new(packet.pack("C*"))

      expect(parsed.option(Takagi::CoAP::Registries::Option::ETAG).bytes).to eq([0x00, 0xFF, 0x00, 0x00])
      expect(parsed.payload).to eq('{"blob":"x"}')
    end

    it "normalizes Content-Format and decodes the JSON body through #data" do
      body = '{"device_id":"dev-1"}'
      packet = [0x40, 0x02, 0x12, 0x34, 0xC1, 0x32].pack("C*") + "\xFF".b + body
      parsed = Takagi::Message::Inbound.new(packet)

      expect(parsed.content_format).to eq(50)
      expect(parsed.data).to eq({ 'device_id' => 'dev-1' })
    end

    it "returns nil from #data when there is no payload" do
      packet = [0x40, 0x01, 0x12, 0x35].pack("C*")
      expect(Takagi::Message::Inbound.new(packet).data).to be_nil
    end

    it "matches Accept by name and by number" do
      packet = [0x40, 0x01, 0x12, 0x36, 0xD1, 0x04, 0x32].pack("C*")
      parsed = Takagi::Message::Inbound.new(packet)

      expect(parsed.accept).to eq(50)
      expect(parsed.accept?('application/json')).to be(true)
      expect(parsed.accept?(50)).to be(true)
      expect(parsed.accept?('application/cbor')).to be(false)
    end

    it "parses options that use extended delta and length encoding" do
      option_value = "A" * 18
      packet = ''.b
      packet << [0b01000010, 0x01, 0x00, 0x10].pack('C4') # Ver=1, Type=0, TKL=2, Code=GET, MID=0x0010
      packet << [0xAA, 0xBB].pack('C2') # Token
      packet << [0xDD, 0x1A, 0x05].pack('C*') # Option delta=39 (Proxy-Scheme), length=18
      packet << option_value

      parsed = Takagi::Message::Inbound.new(packet)

      expect(parsed.version).to eq(1)
      expect(parsed.token).to eq("\xAA\xBB".b)
      expect(parsed.options[39]).to eq(option_value)
    end

    it "parses options using 16-bit extended delta encoding" do
      packet = ''.b
      packet << [0b01000000, 0x01, 0x00, 0x11].pack('C4') # Ver=1, Type=0, TKL=0, Code=GET, MID=0x0011
      packet << [0xE1].pack('C') # delta raw=14, length=1
      packet << [0x00, 0x1F].pack('C2') # extended delta value 31 -> option number 300
      packet << 'Z'

      parsed = Takagi::Message::Inbound.new(packet)

      expect(parsed.options[300]).to eq('Z')
    end

    it "constructs URI using Uri-Host and multiple Uri-Path segments" do
      packet = ''.b
      packet << [0b01000000, 0x01, 0x12, 0x34].pack('C4') # Ver=1, Type=0, TKL=0, Code=GET, MID=0x1234
      packet << [0x3B].pack('C') # Uri-Host, delta=3, length=11
      packet << 'example.com'
      packet << [0x87].pack('C') # Uri-Path delta=8 length=7 -> 'sensors'
      packet << 'sensors'
      packet << [0x04].pack('C') # Uri-Path delta=0 length=4 -> 'temp'
      packet << 'temp'

      parsed = Takagi::Message::Inbound.new(packet)

      expect(parsed.options[3]).to eq('example.com')
      expect(parsed.options[11]).to eq(%w[sensors temp])
      expect(parsed.uri.host).to eq('example.com')
      expect(parsed.uri.path).to eq('/sensors/temp')
    end

    it "builds piggybacked ACK responses for confirmable exchanges" do
      con_packet = coap_get_packet.dup
      con_packet.setbyte(0, 0b01000001) # Force Type=0 (CON) while keeping token length

      inbound = Takagi::Message::Inbound.new(con_packet)
      outbound = inbound.to_response('2.05 Content', { message: 'Pong' })
      parsed_response = Takagi::Message::Inbound.new(outbound.to_bytes)

      expect(parsed_response.type).to eq(2) # ACK
      expect(parsed_response.token).to eq(inbound.token)
      expect(parsed_response.message_id).to eq(inbound.message_id)
      expect(parsed_response.code).to eq(69)
    end

    it "keeps responses non-confirmable when request was NON" do
      inbound = Takagi::Message::Inbound.new(coap_get_packet)
      outbound = inbound.to_response('2.05 Content', { message: 'Pong' })
      parsed_response = Takagi::Message::Inbound.new(outbound.to_bytes)

      expect(parsed_response.type).to eq(1)
      expect(parsed_response.code).to eq(69)
    end
  end

  describe "rejecting an unparseable datagram" do
    def parse(bytes, transport: :udp)
      Takagi::Message::Inbound.new(bytes.pack("C*"), transport: transport)
    end

    it "defines ParseError as a StandardError" do
      expect(Takagi::Message::ParseError.superclass).to eq(StandardError)
    end

    it "raises ParseError for an empty datagram" do
      expect { parse([]) }.to raise_error(Takagi::Message::ParseError, /shorter than the 4-byte CoAP header \(0 bytes\)/)
    end

    it "raises ParseError for a 1-byte datagram" do
      expect { parse([0x40]) }.to raise_error(Takagi::Message::ParseError, /shorter than the 4-byte CoAP header \(1 bytes\)/)
    end

    it "raises ParseError for a 2-byte datagram" do
      expect { parse([0x40, 0x00]) }.to raise_error(Takagi::Message::ParseError, /shorter than the 4-byte CoAP header \(2 bytes\)/)
    end

    it "raises ParseError for a 3-byte datagram" do
      expect { parse([0x40, 0x00, 0x01]) }.to raise_error(Takagi::Message::ParseError, /shorter than the 4-byte CoAP header \(3 bytes\)/)
    end

    it "raises ParseError when the token length overruns the datagram" do
      expect { parse([0x41, 0x00, 0x12, 0x34]) }.to raise_error(Takagi::Message::ParseError, /token length 1 runs past the end of the message/)
    end

    it "raises ParseError when an option value runs past the end of the datagram" do
      expect { parse([0x40, 0x01, 0x12, 0x34, 0x24]) }.to raise_error(Takagi::Message::ParseError, /option 2 of 4 bytes overruns the datagram/)
    end

    it "raises ParseError when an option extension runs past the end of the datagram" do
      expect { parse([0x40, 0x01, 0x12, 0x34, 0xD1]) }.to raise_error(Takagi::Message::ParseError, /1-byte extension past the end of the message/)
    end

    it "raises ParseError for a TCP frame shorter than its header" do
      expect { parse([], transport: :tcp) }.to raise_error(Takagi::Message::ParseError, /2-byte CoAP-over-TCP header \(0 bytes\)/)
    end

    it "parses a 0.00 message with trailing bytes without walking options" do
      parsed = parse([0x40, 0x00, 0x45, 0x67, 0x5A])

      expect(parsed.code).to eq(0)
      expect(parsed.options).to eq({})
      expect(parsed.payload).to be_nil
    end

    it "still parses a datagram whose token length matches the bytes present" do
      parsed = parse([0x41, 0x01, 0x12, 0x34, 0xAA])

      expect(parsed.token).to eq("\xAA".b)
      expect(parsed.message_id).to eq(0x1234)
      expect(parsed.options).to eq({})
    end
  end

  describe Takagi::Message::Outbound do
    it "builds a CoAP response with JSON payload" do
      message = Takagi::Message::Outbound.new(
        code: "2.05",
        payload: { message: "Pong" },
        token: "\xAA".b,
        message_id: 0x1234
      )

      packet = message.to_bytes

      expect(packet.bytesize).to be > 5
      expect(packet.force_encoding("ASCII-8BIT")).to include("\xFF".b) # payload marker
      expect(packet.force_encoding("ASCII-8BIT")).to include("Pong".b)
    end

    it "builds minimal CoAP response without payload" do
      message = Takagi::Message::Outbound.new(
        code: "2.05",
        payload: "",
        token: "\xBB".b,
        message_id: 0x4567
      )

      packet = message.to_bytes

      expect(packet.bytesize).to be > 4
      expect(packet.force_encoding("ASCII-8BIT")).not_to include("\xFF".b)
    end

    it "encodes integer options without leading zero bytes" do
      message = Takagi::Message::Outbound.new(
        code: Takagi::CoAP::Registries::Signaling::CSM,
        payload: "",
        token: "",
        message_id: 0,
        type: 0,
        options: { 2 => 8_388_864 },
        transport: :tcp
      )

      bytes = message.to_bytes(transport: :tcp)

      expect(bytes.getbyte(2)).to eq(0x23) # delta=2, length=3
      expect(bytes.byteslice(3, 3).bytes).to eq([0x80, 0x01, 0x00])
    end

    it "serializes a code 0.00 message as the bare 4-byte header" do
      message = Takagi::Message::Outbound.new(
        code: "0.00",
        type: 3,
        message_id: 0x1234,
        payload: "",
        token: ""
      )

      bytes = message.to_bytes

      expect(bytes.bytesize).to eq(4)
      expect(bytes.unpack1("H*")).to eq("70001234")
    end

    it "serializes a code 0.00 message over TCP as the bare 2-byte frame" do
      message = Takagi::Message::Outbound.new(
        code: "0.00",
        type: 3,
        message_id: 0x1234,
        payload: "",
        token: ""
      )

      expect(message.to_bytes(transport: :tcp).unpack1("H*")).to eq("0000")
    end

    it "keeps ordinary message bytes unchanged" do
      message = Takagi::Message::Outbound.new(
        code: "2.05",
        type: 2,
        payload: "Pong",
        token: "\xAA".b,
        message_id: 0x1234
      )

      expect(message.to_bytes.unpack1("H*")).to eq("61451234aaff506f6e67")
    end

    it "raises when an Empty message carries a payload" do
      message = Takagi::Message::Outbound.new(
        code: "0.00",
        type: 3,
        message_id: 0x1234,
        payload: "x",
        token: ""
      )

      expect { message.to_bytes }.to raise_error(Takagi::Network::Framing::EmptyMessageError, /bare header/)
    end

    it "raises when an Empty message carries options" do
      message = Takagi::Message::Outbound.new(
        code: "0.00",
        type: 2,
        message_id: 0x1234,
        payload: "",
        token: "",
        options: { 2 => 1 }
      )

      expect { message.to_bytes }.to raise_error(Takagi::Network::Framing::EmptyMessageError, /bare header/)
    end

    it "raises when an Empty message carries a token" do
      message = Takagi::Message::Outbound.new(
        code: "0.00",
        type: 2,
        message_id: 0x1234,
        payload: "",
        token: "\xAA".b
      )

      expect { message.to_bytes }.to raise_error(Takagi::Network::Framing::EmptyMessageError, /bare header/)
    end

    it "raises when a Reset carries a code or a payload" do
      reset = Takagi::Message::Outbound.new(
        code: "4.04",
        type: 3,
        message_id: 0x1234,
        payload: '{"error":"not found"}',
        token: ""
      )

      expect { reset.to_bytes }.to raise_error(Takagi::Network::Framing::EmptyMessageError, /Reset/)
    end

    it "raises when an Empty TCP message carries a payload" do
      message = Takagi::Message::Outbound.new(
        code: "0.00",
        type: 3,
        message_id: 0x1234,
        payload: "x",
        token: "",
        transport: :tcp
      )

      expect { message.to_bytes(transport: :tcp) }
        .to raise_error(Takagi::Network::Framing::EmptyMessageError, /bare header/)
    end
  end

  describe Takagi::Message::Request do
    it "refuses a Reset carrying an option and a payload" do
      message = Takagi::Message::Request.new(method: :post, uri: URI('coap://localhost/x'),
                                             type: 3, payload: 'body', token: "\xAA".b,
                                             message_id: 0x1234)

      expect { message.to_bytes }
        .to raise_error(Takagi::Network::Framing::EmptyMessageError, /bare header/)
    end

    it "serializes a Reset without a payload as the bare 4-byte header" do
      message = Takagi::Message::Request.new(method: :post, uri: URI('coap://localhost/x'),
                                             type: 3, message_id: 0x1234)

      expect(message.to_bytes.unpack1('H*')).to eq('70001234')
    end

    it "serializes a Reset with an empty payload as the bare 4-byte header" do
      message = Takagi::Message::Request.new(method: :post, uri: URI('coap://localhost'),
                                             type: 3, payload: '', message_id: 0x1234)

      expect(message.to_bytes.unpack1('H*')).to eq('70001234')
    end

    {
      '41011234aab470696e67' =>
        { method: :get, uri: URI('coap://localhost/ping'), token: "\xAA".b, message_id: 0x1234 },
      '41022222bbb17843793d31ff626f6479' =>
        { method: :post, uri: URI('coap://localhost/x?y=1'), payload: 'body', token: "\xBB".b, message_id: 0x2222 },
      '44033333746b3031b1610162ff7b226b223a2276227d' =>
        { method: :put, uri: URI('coap://localhost/a/b'), payload: { k: 'v' }, token: 'tk01', message_id: 0x3333 },
      '41024444ccb1781132ff78' =>
        { method: :post, uri: URI('coap://localhost/x'), payload: 'x', token: "\xCC".b, message_id: 0x4444,
          options: { 12 => 50 } },
      '51015555ddb773656e736f72730474656d70' =>
        { method: :get, uri: URI('coap://localhost/sensors/temp'), token: "\xDD".b, message_id: 0x5555, type: 1 }
    }.each do |expected, kwargs|
      it "keeps ordinary request bytes unchanged (#{kwargs[:method]})" do
        expect(Takagi::Message::Request.new(**kwargs).to_bytes.unpack1('H*')).to eq(expected)
      end
    end
  end
end
