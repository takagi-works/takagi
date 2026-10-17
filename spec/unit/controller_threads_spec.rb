# frozen_string_literal: true

require 'timeout'
require 'socket'

# Row 9 of .omo/plans/tcp-multi-worker.md, pinned three ways:
#
# 1. The allocator's dead per-controller process machinery is gone: it allocates each
#    controller a THREAD count and nothing else, and the minimal-profile fallback still
#    hands a processes-only controller a usable thread count.
# 2. A controller's `threads` is a real pool size in the process that started it, and a
#    FORKED worker - whose pool threads died with the fork - answers a request whose path
#    maps to that controller through the synchronous branch instead of queueing into a
#    queue nobody drains.
# 3. The RECORDED TCP MODEL: TCP keeps the connection-thread model (one thread per
#    connection reads and writes, in order), so a controller's `threads` governs only that
#    controller's own pool work and a TCP request is never served from the pool. The first
#    branch of row 9's item (3) - delegating TCP to the controller pool - was rejected
#    because `lib/takagi/server/tcp.rb` is owned by another lane in this wave, and it is
#    not needed: one connection is one ordered read/write sequence on its own thread.
RSpec.describe 'Controller threads on both transports (plan row 9)' do
  around do |example|
    stack = Takagi::MiddlewareStack.instance
    previous_router = stack.router
    example.run
  ensure
    stack.instance_variable_set(:@router, previous_router)
  end

  # A controller with its own isolated router, mounted at +mount+, answering GET /hello.
  def pooled_controller(constant: 'PooledController', mount: '/pooled', threads: nil, processes: nil, &handler)
    klass = Class.new(Takagi::Controller)
    klass.configure do
      mount mount
      set :threads, threads if threads
      set :processes, processes if processes
    end
    klass.get('/hello', &(handler || proc { { message: 'Pong', handled_by: Thread.current.name.to_s } }))
    stub_const(constant, klass)
    klass
  end

  # Point the middleware stack's route lookup at a composite router that maps the
  # controller's mount path to the controller's own router, so both the path lookup (the
  # UDP worker) and the route lookup resolve to the same controller.
  def route_to(controller)
    router = Takagi::CompositeRouter.new
    router.mount(controller)
    Takagi::MiddlewareStack.instance.instance_variable_set(:@router, router)
    router
  end

  # A CoAP CON GET with one Uri-Path option per segment, plus a one-byte token.
  def coap_get(path, message_id)
    bytes = [0x41, 0x01, (message_id >> 8) & 0xFF, message_id & 0xFF, 0x41]
    previous = 0
    path.split('/').reject(&:empty?).each do |segment|
      bytes += [((11 - previous) << 4) | segment.bytesize] + segment.bytes
      previous = 11
    end
    bytes.pack('C*')
  end

  # Bounded exchange: resend inside a deadline, never sleep for a fixed amount.
  def udp_exchange(socket, request, seconds: 3.0)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    loop do
      socket.send(request, 0)
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return nil if remaining <= 0
      return socket.recvfrom(4096).first if socket.wait_readable(remaining)
    end
  end

  def bound_udp_port(server)
    server.instance_variable_get(:@socket).addr[1]
  end

  # RFC 8323 frames are what the transport registry already hands back from to_bytes, so
  # they are written as-is; only signalling frames (the server's CSM) are skipped here.
  def read_tcp_message(socket)
    loop do
      return nil unless socket.wait_readable(5)

      raw = Takagi::Network::Framing::Tcp.read_from_socket(socket)
      return nil unless raw
      return raw unless Takagi::CoAP::Registries::Signaling.signaling?(raw.getbyte(1))
    end
  end

  def tcp_exchange(client, path, token)
    request = Takagi::Message::Outbound.new(
      code: 1,
      payload: nil,
      token: token,
      options: { 11 => path.split('/').reject(&:empty?) }, # Uri-Path
      transport: :tcp
    )
    client.write(request.to_bytes(transport: :tcp))
    raw = read_tcp_message(client)
    Takagi::Message::Inbound.new(raw, transport: :tcp)
  end

  describe 'the allocator (dead per-controller process machinery)' do
    it 'allocates a controller its thread count and no process claim at all' do
      controller = pooled_controller(threads: 8)

      allocation = Takagi::Controller::ResourceAllocator.allocate(controllers: [controller], mode: :manual)

      expect(allocation[controller]).to eq(threads: 8, mode: :manual)
      expect(allocation[controller]).not_to have_key(:processes)
    end

    it 'writes no process claim in automatic mode either' do
      controller = pooled_controller(threads: 8)

      allocation = Takagi::Controller::ResourceAllocator.allocate(
        controllers: [controller], mode: :automatic, total_threads: 16
      )

      expect(allocation[controller][:threads]).to eq(16)
      expect(allocation[controller]).not_to have_key(:processes)
    end

    it 'gives a controller declaring only processes: 4 a usable thread count (minimal-profile fallback)' do
      controller = pooled_controller(constant: 'ProcessesOnlyController', processes: 4)

      allocation = Takagi::Controller::ResourceAllocator.allocate(controllers: [controller], mode: :manual)

      expect(allocation[controller]).to eq(threads: Takagi::Profiles.get(:minimal)[:threads], mode: :manual)
    end

    it 'still rejects allocations that exceed the available threads' do
      controller = pooled_controller(threads: 40)
      allocations = Takagi::Controller::ResourceAllocator.allocate(controllers: [controller], mode: :manual)

      expect { Takagi::Controller::ResourceAllocator.validate!(allocations, total_threads: 10) }
        .to raise_error(ArgumentError, /exceed available threads/)
    end
  end

  describe "a controller's threads" do
    it 'is the size of its own pool, independent of the server-wide thread setting' do
      controller = pooled_controller(threads: 8)
      previous_server_threads = Takagi.config.threads
      Takagi.config.threads = 2
      allocation = Takagi::Controller::ResourceAllocator.allocate(controllers: [controller], mode: :manual)

      pool = controller.start_workers!(threads: allocation[controller][:threads], name: 'PooledController')

      expect(pool.size).to eq(8)
      expect(Takagi.config.threads).to eq(2)

      # Eight jobs are picked up at the same time only if the pool really has eight
      # workers: hold every one of them, then release.
      started = Queue.new
      release = Queue.new
      8.times { controller.schedule { started << :running; release.pop } }
      8.times { expect(Timeout.timeout(5) { started.pop }).to eq(:running) }
    ensure
      8.times { release << :go } if release
      controller&.shutdown_workers!
      Takagi.config.threads = previous_server_threads
      # Row 30 of .omo/plans/tcp-multi-worker.md: the VALUE is back, the presence is not -
      # `threads=` recorded `:threads` as WRITTEN and it stays written for the rest of the
      # process, so a later build that reaches the real singleton warns about a key nobody
      # wrote in it. Hand the presence back the way the suite does (row 23's API).
      Takagi.config.reset_written_keys!
    end

    it 'starts the pool of a controller that declares only processes, through the application pool loop' do
      pooled_controller(constant: 'ProcessesOnlyController', processes: 4)
      app = Class.new(Takagi::Application) do
        configure { load_controllers ProcessesOnlyController }
      end
      app.config[:allocation_mode] = :manual

      app.start_all_workers!

      expect(ProcessesOnlyController.workers_running?).to be(true)
      expect(ProcessesOnlyController.thread_pool.size).to eq(Takagi::Profiles.get(:minimal)[:threads])
    ensure
      app&.shutdown_all_workers!
    end
  end

  describe 'a forked worker (the fork fix)' do
    it 'reports no running pool in a forked child, while the pool keeps running here' do
      controller = pooled_controller(threads: 2)
      controller.start_workers!(threads: 2, name: 'PooledController')

      reader, writer = IO.pipe
      child_pid = fork do
        reader.close
        writer.puts(controller.workers_running?.inspect)
        writer.close
        exit!(0)
      end
      writer.close
      reported = Timeout.timeout(10) { reader.gets }
      reader.close

      expect(controller.workers_running?).to be(true)
      expect(reported&.chomp).to eq('false')
    ensure
      reap(child_pid)
      controller&.shutdown_workers!
    end

    it 'answers a request whose path maps to a pooled controller from a forked UDP worker' do
      controller = pooled_controller(threads: 2)
      controller.start_workers!(threads: 2, name: 'PooledController')
      router = route_to(controller)

      server = Takagi::Server::Udp.new(port: 0, worker_processes: 2, worker_threads: 1, router: router)
      port = bound_udp_port(server)
      runner = Thread.new { server.run! }
      server.instance_variable_set(:@server_thread, runner)

      socket = UDPSocket.new
      socket.connect('127.0.0.1', port)
      response = udp_exchange(socket, coap_get('/pooled/hello', 0x5150), seconds: 3.0)

      expect(response).not_to be_nil,
                             'the forked worker answered nothing inside 3s: it queued the request into a pool ' \
                             'whose threads died with the fork'
      expect(response).to include('Pong')
    ensure
      socket&.close
      server&.shutdown!
      runner&.join(5)
      controller&.shutdown_workers!
    end
  end

  describe 'the recorded TCP model (connection threads, not the controller pool)' do
    it 'serves a TCP request on the connection thread while every pool worker is held' do
      controller = pooled_controller(threads: 4)
      controller.start_workers!(threads: 4, name: 'PooledController')
      route_to(controller)

      # Hold every pool worker. If TCP delegated to the controller pool (the rejected
      # branch), the request would sit in the queue and no response could arrive until
      # these jobs were released.
      started = Queue.new
      release = Queue.new
      4.times { controller.schedule { started << :running; release.pop } }
      4.times { expect(Timeout.timeout(5) { started.pop }).to eq(:running) }

      server = Takagi::Server::Tcp.new(port: 0, worker_processes: 1)
      runner = Thread.new { server.run! }
      port = server.instance_variable_get(:@server).addr[1]

      client = TCPSocket.new('127.0.0.1', port)
      first = tcp_exchange(client, '/pooled/hello', 'aaaaaaaa')
      second = tcp_exchange(client, '/pooled/hello', 'bbbbbbbb')

      # One thread per connection reads and writes in order: the responses come back in
      # request order, each with its own token, written by the connection's own thread.
      expect(first.payload).to include('Pong')
      expect(second.payload).to include('Pong')
      expect([first.token, second.token]).to eq(%w[aaaaaaaa bbbbbbbb])
      expect(first.payload).not_to include('PooledController-worker-')

      # The pool was never consulted: nothing was queued and nothing was processed.
      expect(controller.thread_pool.queue_size).to eq(0)
      expect(controller.thread_pool.stats[:processed]).to eq(0)
    ensure
      8.times { release << :go } if release
      client&.close
      server&.shutdown!
      runner&.join(5)
      controller&.shutdown_workers!
    end
  end

  def reap(pid)
    return unless pid

    Process.waitpid(pid)
  rescue Errno::ECHILD
    nil
  end
end
