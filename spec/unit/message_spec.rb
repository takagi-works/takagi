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
  end
end
