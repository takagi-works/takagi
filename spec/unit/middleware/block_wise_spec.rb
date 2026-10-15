# frozen_string_literal: true

require 'digest'
require 'socket'
require 'timeout'

# Routes exercised by the end-to-end block-wise examples below.
class BlockWiseSpecApp < Takagi::Base
  get '/block-wise/big' do
    { blob: 'x' * 4096 }
  end

  post '/block-wise/echo' do |req|
    body = req.payload.to_s
    { size: body.bytesize, digest: Digest::SHA256.hexdigest(body) }
  end
end

RSpec.describe Takagi::Middleware::BlockWise do
  let(:option_value) { Takagi::CoAP::BlockWise::OptionValue }
  let(:settings) do
    Takagi::Config::BlockWiseConfig.new(szx: 6, max_assembled_bytes: 1_048_576, assembly_ttl: 30,
                                        max_concurrent_assemblies: 64, enabled: true)
  end

  def build_inbound(method:, path:, options: {}, token: "\x11\x22".b, message_id: 0x1234, payload: nil)
    Takagi::Message::Inbound.new(build_packet(method: method, path: path, options: options, token: token,
                                              message_id: message_id, payload: payload))
  end

  def build_packet(method:, path:, options: {}, token: "\x11\x22".b, message_id: 0x1234, payload: nil)
    entries = path_segments(path)
    options.each { |number, value| entries << [number, value] }
    packet = [0x40 | token.bytesize, method_code(method), (message_id >> 8) & 0xFF, message_id & 0xFF].pack('C*')
    packet += token + encode_options(entries)
    packet += "\xFF".b + payload.b if payload
    packet
  end

  def path_segments(path)
    path.split('/').reject(&:empty?).map { |segment| [Takagi::CoAP::Registries::Option::URI_PATH, segment] }
  end

  def method_code(method)
    { get: 1, post: 2, put: 3 }[method]
  end

  def block2(num:, more:, szx:)
    { Takagi::CoAP::Registries::Option::BLOCK2 => option_value.encode(num: num, more: more, szx: szx) }
  end

  def block1(num:, more:, szx:)
    { Takagi::CoAP::Registries::Option::BLOCK1 => option_value.encode(num: num, more: more, szx: szx) }
  end

  def opt(message, number)
    Array(message.respond_to?(:option) ? message.option(number) : message.options[number]).first
  end

  def decode_block(message, number)
    option_value.decode(opt(message, number))
  end

  def uint_value(bytes)
    bytes.to_s.b.bytes.reduce(0) { |acc, byte| (acc << 8) | byte }
  end

  def as_block(message, decoded)
    Takagi::CoAP::BlockWise::Block.new(num: decoded.num, more: decoded.more?, szx: decoded.szx, payload: message.payload)
  end

  describe 'Block2 response slicing' do
    let(:middleware) { described_class.new(config: settings) }

    it 'serves a multi-block response that reassembles to the original representation' do
      blocks = []
      etags = []
      size2 = nil

      20.times do |num|
        request = build_inbound(method: :get, path: '/big', message_id: 0x2000 + num, options: block2(num: num, more: false, szx: 6))
        response = middleware.call(request) { { blob: 'x' * 4096 } }
        decoded = decode_block(response, Takagi::CoAP::Registries::Option::BLOCK2)

        expect(decoded.num).to eq(num)
        expect(decoded.szx).to eq(6)
        expect(response.code).to eq(Takagi::CoAP::Registries::Response::CONTENT)
        blocks << as_block(response, decoded)
        etags << opt(response, Takagi::CoAP::Registries::Option::ETAG)
        size2 ||= opt(response, Takagi::CoAP::Registries::Option::SIZE2)
        break unless decoded.more?
      end

      expect(blocks.size).to eq(5)
      expect(blocks[0..-2].map(&:more?)).to all(eq(true))
      expect(blocks.last.more?).to be(false)
      expect(blocks[0, 4].map { |block| block.payload.bytesize }).to all(eq(1024))

      reassembled = Takagi::CoAP::BlockWise.join(blocks)
      expect(reassembled.bytesize).to eq(4107)
      expect(JSON.parse(reassembled)).to eq('blob' => 'x' * 4096)
      expect(uint_value(size2)).to eq(reassembled.bytesize)
      expect(etags.uniq.size).to eq(1)
      expect(etags.first.bytesize).to eq(8)
    end

    it 'puts Size2 only on the first block' do
      first = middleware.call(build_inbound(method: :get, path: '/big', options: block2(num: 0, more: false, szx: 6))) { { blob: 'x' * 4096 } }
      second = middleware.call(build_inbound(method: :get, path: '/big', message_id: 0x1235, options: block2(num: 1, more: false, szx: 6))) { { blob: 'x' * 4096 } }

      expect(opt(first, Takagi::CoAP::Registries::Option::SIZE2)).not_to be_nil
      expect(opt(second, Takagi::CoAP::Registries::Option::SIZE2)).to be_nil
    end

    it 'honours a smaller SZX than the server default' do
      response = middleware.call(build_inbound(method: :get, path: '/big', options: block2(num: 0, more: false, szx: 2))) { { blob: 'x' * 4096 } }

      expect(decode_block(response, Takagi::CoAP::Registries::Option::BLOCK2).szx).to eq(2)
      expect(response.payload.bytesize).to eq(64)
      expect(response.payload).to eq(Takagi::ResponseBuilder.respond(build_inbound(method: :get, path: '/big'), { blob: 'x' * 4096 }).payload.byteslice(0, 64))
    end

    it 'never offers a larger SZX than the server is configured for' do
      small_blocks = described_class.new(config: Takagi::Config::BlockWiseConfig.new(szx: 2, enabled: true))
      response = small_blocks.call(build_inbound(method: :get, path: '/big', options: block2(num: 0, more: false, szx: 6))) { { blob: 'x' * 4096 } }

      expect(decode_block(response, Takagi::CoAP::Registries::Option::BLOCK2).szx).to eq(2)
      expect(response.payload.bytesize).to eq(64)
    end

    it 'leaves a response that fits in one block untouched' do
      response = middleware.call(build_inbound(method: :get, path: '/small')) { { ok: true } }

      expect(response.payload).to eq('{"ok":true}')
      expect(opt(response, Takagi::CoAP::Registries::Option::BLOCK2)).to be_nil
    end

    it 'reads a zero-length Block2 option as NUM 0, M 0 and SZX 0 (RFC 7252 §3.2)' do
      response = middleware.call(build_inbound(method: :get, path: '/big', options: { Takagi::CoAP::Registries::Option::BLOCK2 => ''.b })) { { blob: 'x' * 4096 } }
      decoded = decode_block(response, Takagi::CoAP::Registries::Option::BLOCK2)

      expect(decoded.num).to eq(0)
      expect(decoded.szx).to eq(0)
      expect(decoded.more?).to be(true)
      expect(response.payload.bytesize).to eq(16)
    end

    it 'answers 4.02 when the requested NUM is past the end of the representation' do
      response = middleware.call(build_inbound(method: :get, path: '/small', options: block2(num: 1, more: false, szx: 6))) { { ok: true } }

      expect(response.code).to eq(Takagi::CoAP::Registries::Response::BAD_OPTION)
    end

    it 'answers 4.02 for a malformed Block2 option value' do
      request = build_inbound(method: :get, path: '/big',
                              options: { Takagi::CoAP::Registries::Option::BLOCK2 => "\x01\x02\x03\x04".b })
      response = middleware.call(request) { { blob: 'x' * 4096 } }

      expect(response.code).to eq(Takagi::CoAP::Registries::Response::BAD_OPTION)
    end

    it 'leaves non-success responses untouched' do
      request = build_inbound(method: :get, path: '/missing')
      response = middleware.call(request) { |req| req.to_response('4.04 Not Found', { error: 'x' * 4096 }) }

      expect(response.code).to eq(Takagi::CoAP::Registries::Response::NOT_FOUND)
      expect(opt(response, Takagi::CoAP::Registries::Option::BLOCK2)).to be_nil
    end

    it 'stays out of the way of TCP messages, which carry no Message ID' do
      request = instance_double(Takagi::Message::Inbound, message_id: nil)
      response = middleware.call(request) { { blob: 'x' * 4096 } }

      expect(response).to eq(blob: 'x' * 4096)
    end

    it 'is inert when the feature is disabled' do
      disabled = described_class.new(config: Takagi::Config::BlockWiseConfig.new(szx: 6, enabled: false))
      response = disabled.call(build_inbound(method: :get, path: '/big')) { { blob: 'x' * 4096 } }

      expect(response).to eq(blob: 'x' * 4096)
    end
  end

  describe 'Block1 request assembly' do
    let(:middleware) { described_class.new(config: settings) }

    it 'reassembles a four-block body and hands the handler one payload' do
      body = 'B' * 4096
      received = []
      codes = []

      Takagi::CoAP::BlockWise.slice(body, szx: 6).each_with_index do |block, index|
        request = build_inbound(method: :post, path: '/echo', message_id: 0x3000 + index, payload: block.payload,
                                options: block1(num: block.num, more: block.more?, szx: block.szx))
        response = middleware.call(request) { |req| received << req; { size: req.payload.bytesize } }
        codes << response.code
      end

      expect(codes[0..2]).to all(eq(Takagi::CoAP::Registries::Response::CONTINUE))
      expect(codes.last).to eq(Takagi::CoAP::Registries::Response::CONTENT)
      expect(received.size).to eq(1)
      expect(received.first.payload).to eq(body)
      expect(received.first.options).not_to have_key(Takagi::CoAP::Registries::Option::BLOCK1)
    end

    it 'echoes the Block1 option on every 2.31 Continue' do
      request = build_inbound(method: :post, path: '/echo', payload: 'B' * 1024, options: block1(num: 0, more: true, szx: 6))
      response = middleware.call(request) { |_req| {} }
      echoed = decode_block(response, Takagi::CoAP::Registries::Option::BLOCK1)

      expect(response.code).to eq(Takagi::CoAP::Registries::Response::CONTINUE)
      expect(echoed.num).to eq(0)
      expect(echoed.more?).to be(true)
      expect(echoed.szx).to eq(6)
    end

    it 'passes a single-block Block1 request straight through' do
      request = build_inbound(method: :post, path: '/echo', payload: 'short', options: block1(num: 0, more: false, szx: 6))
      received = nil
      response = middleware.call(request) { |req| received = req; { ok: true } }

      expect(response.code).to eq(Takagi::CoAP::Registries::Response::CONTENT)
      expect(received.payload).to eq('short')
    end

    it 'slices the handler response of a completed Block1 sequence when Block2 was requested' do
      blocks = Takagi::CoAP::BlockWise.slice('B' * 4096, szx: 6)
      sliced = middleware.call(build_inbound(method: :post, path: '/echo', message_id: 0x3500, payload: blocks[0].payload,
                                             options: block1(num: 0, more: true, szx: 6))) { |_req| {} }
      response = middleware.call(build_inbound(method: :post, path: '/echo', message_id: 0x3501, payload: blocks[1].payload,
                                               options: block1(num: 1, more: false, szx: 6).merge(block2(num: 0, more: false, szx: 6)))) { |_req| { blob: 'x' * 4096 } }

      expect(sliced.code).to eq(Takagi::CoAP::Registries::Response::CONTINUE)
      expect(response.code).to eq(Takagi::CoAP::Registries::Response::CONTENT)
      expect(decode_block(response, Takagi::CoAP::Registries::Option::BLOCK2).more?).to be(true)
      expect(response.payload.bytesize).to eq(1024)
    end

    it 'answers 4.08 for a dropped middle block and drops the assembly' do
      blocks = Takagi::CoAP::BlockWise.slice('B' * 4096, szx: 6)
      first = middleware.call(build_inbound(method: :post, path: '/gap', message_id: 0x4000, payload: blocks[0].payload,
                                            options: block1(num: 0, more: true, szx: 6))) { |_req| {} }
      dropped = middleware.call(build_inbound(method: :post, path: '/gap', message_id: 0x4002, payload: blocks[2].payload,
                                              options: block1(num: 2, more: true, szx: 6))) { |_req| {} }
      after = middleware.call(build_inbound(method: :post, path: '/gap', message_id: 0x4003, payload: blocks[3].payload,
                                            options: block1(num: 3, more: false, szx: 6))) { |_req| {} }

      expect(first.code).to eq(Takagi::CoAP::Registries::Response::CONTINUE)
      expect(dropped.code).to eq(Takagi::CoAP::Registries::Response::REQUEST_ENTITY_INCOMPLETE)
      expect(after.code).to eq(Takagi::CoAP::Registries::Response::REQUEST_ENTITY_INCOMPLETE)
    end

    it 'answers 4.13 with the Size1 cap when the body exceeds max_assembled_bytes' do
      capped = described_class.new(config: Takagi::Config::BlockWiseConfig.new(szx: 6, max_assembled_bytes: 2048, enabled: true))
      codes = []
      last = nil

      [0, 1, 2].each do |index|
        request = build_inbound(method: :post, path: '/cap', message_id: 0x5000 + index, payload: 'B' * 1024,
                                options: block1(num: index, more: index < 2, szx: 6))
        last = capped.call(request) { |_req| {} }
        codes << last.code
      end

      expect(codes).to eq([Takagi::CoAP::Registries::Response::CONTINUE,
                           Takagi::CoAP::Registries::Response::CONTINUE,
                           Takagi::CoAP::Registries::Response::REQUEST_ENTITY_TOO_LARGE])
      expect(uint_value(opt(last, Takagi::CoAP::Registries::Option::SIZE1))).to eq(2048)
    end

    it 'evicts an assembly that outlives assembly_ttl' do
      now = 0.0
      ttl_middleware = described_class.new(config: settings, clock: -> { now })
      blocks = Takagi::CoAP::BlockWise.slice('B' * 4096, szx: 6)

      first = ttl_middleware.call(build_inbound(method: :post, path: '/ttl', message_id: 0x6000, payload: blocks[0].payload,
                                                options: block1(num: 0, more: true, szx: 6))) { |_req| {} }
      now = 100.0
      late = ttl_middleware.call(build_inbound(method: :post, path: '/ttl', message_id: 0x6001, payload: blocks[1].payload,
                                               options: block1(num: 1, more: true, szx: 6))) { |_req| {} }

      expect(first.code).to eq(Takagi::CoAP::Registries::Response::CONTINUE)
      expect(late.code).to eq(Takagi::CoAP::Registries::Response::REQUEST_ENTITY_INCOMPLETE)
    end

    it 'evicts the oldest assembly when max_concurrent_assemblies is reached' do
      capped = described_class.new(config: Takagi::Config::BlockWiseConfig.new(szx: 6, max_concurrent_assemblies: 1, enabled: true))
      blocks = Takagi::CoAP::BlockWise.slice('B' * 4096, szx: 6)

      capped.call(build_inbound(method: :post, path: '/a', token: "\x01".b, message_id: 0x7000, payload: blocks[0].payload,
                                options: block1(num: 0, more: true, szx: 6))) { |_req| {} }
      capped.call(build_inbound(method: :post, path: '/b', token: "\x02".b, message_id: 0x7001, payload: blocks[0].payload,
                                options: block1(num: 0, more: true, szx: 6))) { |_req| {} }
      evicted = capped.call(build_inbound(method: :post, path: '/a', token: "\x01".b, message_id: 0x7002, payload: blocks[1].payload,
                                          options: block1(num: 1, more: true, szx: 6))) { |_req| {} }

      expect(evicted.code).to eq(Takagi::CoAP::Registries::Response::REQUEST_ENTITY_INCOMPLETE)
    end

    it 'keeps assemblies of different tokens and paths apart' do
      blocks = Takagi::CoAP::BlockWise.slice('B' * 4096, szx: 6)
      middleware.call(build_inbound(method: :post, path: '/a', token: "\x01".b, message_id: 0x7100, payload: blocks[0].payload,
                                    options: block1(num: 0, more: true, szx: 6))) { |_req| {} }
      middleware.call(build_inbound(method: :post, path: '/b', token: "\x02".b, message_id: 0x7101, payload: blocks[0].payload,
                                    options: block1(num: 0, more: true, szx: 6))) { |_req| {} }
      received = nil
      response = middleware.call(build_inbound(method: :post, path: '/a', token: "\x01".b, message_id: 0x7102, payload: blocks[1].payload,
                                               options: block1(num: 1, more: false, szx: 6))) { |req| received = req; { ok: true } }

      expect(response.code).to eq(Takagi::CoAP::Registries::Response::CONTENT)
      expect(received.payload.bytesize).to eq(2048)
    end

    it 'answers 4.02 for a malformed Block1 option value' do
      request = build_inbound(method: :post, path: '/echo', payload: 'B' * 1024,
                              options: { Takagi::CoAP::Registries::Option::BLOCK1 => "\x01\x02\x03\x04".b })
      response = middleware.call(request) { |_req| {} }

      expect(response.code).to eq(Takagi::CoAP::Registries::Response::BAD_OPTION)
    end
  end

  describe 'observability hooks' do
    let(:middleware) { described_class.new(config: settings) }

    def subscribe(event)
      queue = Queue.new
      [queue, Takagi::Hooks.subscribe(event) { |payload| queue << payload }]
    end

    def next_payload(queue)
      Timeout.timeout(5) { queue.pop }
    end

    it 'emits block_transfer_started and block_transfer_completed for a Block2 transfer' do
      started, started_handler = subscribe(:block_transfer_started)
      completed, completed_handler = subscribe(:block_transfer_completed)

      middleware.call(build_inbound(method: :get, path: '/big', options: block2(num: 0, more: false, szx: 6))) { { blob: 'x' * 4096 } }
      middleware.call(build_inbound(method: :get, path: '/big', message_id: 0x1235, options: block2(num: 4, more: false, szx: 6))) { { blob: 'x' * 4096 } }

      expect(next_payload(started)).to include(direction: :block2, num: 0, szx: 6, size: 4107, path: '/big')
      expect(next_payload(completed)).to include(direction: :block2, num: 4, szx: 6, size: 4107, path: '/big')
    ensure
      Takagi::Hooks.unsubscribe(:block_transfer_started, started_handler)
      Takagi::Hooks.unsubscribe(:block_transfer_completed, completed_handler)
    end

    it 'emits block_transfer_completed when a Block1 sequence finishes' do
      queue, handler = subscribe(:block_transfer_completed)

      Takagi::CoAP::BlockWise.slice('B' * 4096, szx: 6).each_with_index do |block, index|
        middleware.call(build_inbound(method: :post, path: '/echo', message_id: 0x3000 + index, payload: block.payload,
                                      options: block1(num: block.num, more: block.more?, szx: block.szx))) { |_req| {} }
      end

      expect(next_payload(queue)).to include(direction: :block1, num: 3, szx: 6, size: 4096, path: '/echo')
    ensure
      Takagi::Hooks.unsubscribe(:block_transfer_completed, handler)
    end

    it 'emits block_transfer_failed with a reason for a gap and for an over-cap body' do
      queue, handler = subscribe(:block_transfer_failed)
      blocks = Takagi::CoAP::BlockWise.slice('B' * 4096, szx: 6)

      middleware.call(build_inbound(method: :post, path: '/gap', message_id: 0x4000, payload: blocks[0].payload,
                                    options: block1(num: 0, more: true, szx: 6))) { |_req| {} }
      middleware.call(build_inbound(method: :post, path: '/gap', message_id: 0x4002, payload: blocks[2].payload,
                                    options: block1(num: 2, more: true, szx: 6))) { |_req| {} }
      capped = described_class.new(config: Takagi::Config::BlockWiseConfig.new(szx: 6, max_assembled_bytes: 1024, enabled: true))
      capped.call(build_inbound(method: :post, path: '/cap', message_id: 0x4100, payload: 'B' * 1024,
                                options: block1(num: 0, more: true, szx: 6))) { |_req| {} }
      capped.call(build_inbound(method: :post, path: '/cap', message_id: 0x4101, payload: 'B' * 1024,
                                options: block1(num: 1, more: false, szx: 6))) { |_req| {} }

      payloads = [next_payload(queue), next_payload(queue)]
      expect(payloads.map { |payload| [payload[:path], payload[:reason], payload[:direction]] })
        .to contain_exactly(['/gap', :out_of_order, :block1], ['/cap', :too_large, :block1])
    ensure
      Takagi::Hooks.unsubscribe(:block_transfer_failed, handler)
    end

    it 'completes the transfer even when a subscriber raises' do
      broken = Takagi::Hooks.subscribe(:block_transfer_started) { raise 'subscriber boom' }
      codes = []

      Takagi::CoAP::BlockWise.slice('B' * 4096, szx: 6).each_with_index do |block, index|
        response = middleware.call(build_inbound(method: :post, path: '/echo', message_id: 0x3000 + index, payload: block.payload,
                                                options: block1(num: block.num, more: block.more?, szx: block.szx))) { |_req| {} }
        codes << response.code
      end

      expect(codes.last).to eq(Takagi::CoAP::Registries::Response::CONTENT)
    ensure
      Takagi::Hooks.unsubscribe(:block_transfer_started, broken)
    end
  end

  describe 'end-to-end over UDP' do
    before do
      @previous_stack = Takagi.config.middleware.stack
      @previous_cap = Takagi.config.block_wise.max_assembled_bytes
      @cap = 1_048_576
    end

    after do
      @socket&.close
      @server&.shutdown!
      @server_thread&.join(5)
      Takagi.config.middleware.stack = @previous_stack
      Takagi.config.block_wise.max_assembled_bytes = @previous_cap
      Takagi::MiddlewareStack.instance.reset!
    end

    # Assembly state lives in the middleware instance and a UDP server hands requests to
    # forked workers, so the endpoints here run the single worker process and thread that
    # `Takagi.config.processes`/`threads` default to: `Base.run!` uses those, while
    # `Base.spawn!` hard-codes two worker processes. Configuration has to be in place
    # before the fork, and every observation has to come back over the wire.
    def start_server
      Takagi.config.middleware.stack = [{ name: 'BlockWise', options: {} }]
      Takagi.config.block_wise.max_assembled_bytes = @cap
      Takagi::MiddlewareStack.instance.reset!
      port = find_free_port
      @server = Takagi::Server::Udp.new(port: port, worker_processes: 1, worker_threads: 1)
      @server_thread = Thread.new { @server.run! }
      @socket = UDPSocket.new
      @address = ['127.0.0.1', port]
      @server
    end

    def exchange(method:, path:, options: {}, token: "\xAA\xBB".b, message_id:, payload: nil)
      packet = build_packet(method: method, path: path, options: options, token: token,
                            message_id: message_id, payload: payload)
      @socket.send(packet, 0, *@address)
      raise 'no CoAP response within 5s' unless IO.select([@socket], nil, nil, 5)

      Takagi::Message::Inbound.new(@socket.recvfrom(65_535).first)
    end

    it 'serves a 4 KiB GET as blocks that reassemble to the representation' do
      server = start_server
      blocks = []
      etags = []
      declared_size = nil

      20.times do |num|
        message = exchange(method: :get, path: '/block-wise/big', message_id: 0x5000 + num,
                           options: block2(num: num, more: false, szx: 5))
        decoded = decode_block(message, Takagi::CoAP::Registries::Option::BLOCK2)

        expect(decoded.num).to eq(num)
        expect(decoded.szx).to eq(5)
        blocks << as_block(message, decoded)
        etags << opt(message, Takagi::CoAP::Registries::Option::ETAG)
        declared_size ||= uint_value(opt(message, Takagi::CoAP::Registries::Option::SIZE2))
        break unless decoded.more?
      end

      expect(blocks.size).to be > 1
      reassembled = Takagi::CoAP::BlockWise.join(blocks)
      expect(JSON.parse(reassembled)).to eq('blob' => 'x' * 4096)
      expect(declared_size).to eq(reassembled.bytesize)
      expect(etags.uniq.size).to eq(1)
    ensure
      @socket.close
      server.shutdown!
    end

    it 'reassembles a 4 KiB POST into one payload for the handler' do
      server = start_server
      body = 'z' * 4096
      codes = []
      last = nil

      Takagi::CoAP::BlockWise.slice(body, szx: 5).each_with_index do |block, index|
        last = exchange(method: :post, path: '/block-wise/echo', message_id: 0x6000 + index, payload: block.payload,
                        options: block1(num: block.num, more: block.more?, szx: block.szx))
        codes << last.code
      end

      expect(codes[0..-2]).to all(eq(Takagi::CoAP::Registries::Response::CONTINUE))
      expect(codes.last).to eq(Takagi::CoAP::Registries::Response::CONTENT)
      echo = JSON.parse(last.payload)
      expect(echo['size']).to eq(4096)
      expect(echo['digest']).to eq(Digest::SHA256.hexdigest(body))
    ensure
      @socket.close
      server.shutdown!
    end

    it 'answers 4.08 when a middle block never arrives' do
      server = start_server
      blocks = Takagi::CoAP::BlockWise.slice('z' * 4096, szx: 5)

      first = exchange(method: :post, path: '/block-wise/echo', message_id: 0x6100, payload: blocks[0].payload,
                       options: block1(num: 0, more: true, szx: 5))
      dropped = exchange(method: :post, path: '/block-wise/echo', message_id: 0x6102, payload: blocks[2].payload,
                         options: block1(num: 2, more: true, szx: 5))

      expect(first.code).to eq(Takagi::CoAP::Registries::Response::CONTINUE)
      expect(dropped.code).to eq(Takagi::CoAP::Registries::Response::REQUEST_ENTITY_INCOMPLETE)
    ensure
      @socket.close
      server.shutdown!
    end

    it 'answers 4.13 when the posted body exceeds the configured cap' do
      @cap = 2048
      server = start_server
      codes = []
      last = nil

      [0, 1, 2].each do |index|
        last = exchange(method: :post, path: '/block-wise/echo', message_id: 0x6200 + index, payload: 'z' * 1024,
                        options: block1(num: index, more: index < 2, szx: 6))
        codes << last.code
      end

      expect(codes.last).to eq(Takagi::CoAP::Registries::Response::REQUEST_ENTITY_TOO_LARGE)
      expect(uint_value(opt(last, Takagi::CoAP::Registries::Option::SIZE1))).to eq(2048)
    ensure
      @socket.close
      server.shutdown!
    end
  end
end
