# frozen_string_literal: true

require 'timeout'

RSpec.describe 'Takagi TCP multi-worker server' do
  def bound_port(server)
    server.instance_variable_get(:@server).addr[1]
  end

  def await_worker_title(pid, expected, seconds: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      title = begin
        File.read("/proc/#{pid}/cmdline").split("\0").first
      rescue Errno::ENOENT, Errno::ESRCH
        nil
      end
      return title if title == expected

      sleep 0.01
    end
    nil
  end

  # ROW 15: a PASS-THROUGH on purpose. `to_bytes(transport: :tcp)` already returns an
  # RFC 8323 frame; this helper used to re-implement the library's private framing
  # algorithm, which DOUBLE-frames anything larger than the 15-byte ping it was written
  # for. Measured against the old body: a request with an 8-byte payload came out 26 bytes
  # instead of 25, 24 bytes became 42, 64 became 82, and a 300-byte payload became 320
  # bytes whose Code byte decoded to 0x00 - an empty frame, which a serving process reads,
  # ignores and then WAITS on. It stays a named seam so the call site reads unchanged, and
  # 'keeps the frame helper a pass-through for a payload beyond the ping' pins it.
  def encode_tcp_frame(data) = data

  def read_tcp_message(socket)
    loop do
      return nil unless socket.wait_readable(5)

      raw = Takagi::Network::Framing::Tcp.read_from_socket(socket)
      return nil unless raw
      return raw unless Takagi::CoAP::Registries::Signaling.signaling?(raw.getbyte(1))
    end
  end

  def ping_over_tcp(port)
    client = TCPSocket.new('127.0.0.1', port)
    request = Takagi::Message::Outbound.new(
      code: 1, # GET
      payload: nil,
      token: '12345678',
      options: { 11 => ['ping'] }, # Uri-Path
      transport: :tcp
    )
    client.write(encode_tcp_frame(request.to_bytes(transport: :tcp)))
    response = read_tcp_message(client)
    client.close
    Takagi::Message::Inbound.new(response, transport: :tcp)
  end

  # The library's own framing, never re-framed by hand: `to_bytes(transport: :tcp)`
  # already returns an RFC 8323 frame.
  def ping_frame
    Takagi::Message::Outbound.new(
      code: 1, # GET
      payload: nil,
      token: '12345678',
      options: { 11 => ['ping'] }, # Uri-Path
      transport: :tcp
    ).to_bytes(transport: :tcp)
  end

  # The same exchange as ping_over_tcp, on a socket the CALLER owns, so a spec can keep
  # a connection open and observe what the handler model does with the next one.
  def ping_on(socket)
    socket.write(ping_frame)
    raw = read_tcp_message(socket)
    raw && Takagi::Message::Inbound.new(raw, transport: :tcp)
  end

  def open_connections(port, count)
    Array.new(count) { TCPSocket.new('127.0.0.1', port) }
  end

  def pool_of(server)
    server.instance_variable_get(:@pool)
  end

  def close_quietly(*sockets)
    sockets.compact.each { |socket| socket.close unless socket.closed? }
  rescue IOError, Errno::EBADF
    nil
  end

  # The children of a spawned master are grandchildren of this process, so the only
  # process we can waitpid on is the master itself. A child that its own parent
  # reaped has no /proc entry left; a NOT-reaped one is a zombie and does, which is
  # exactly the case a bare kill(0) would misread as alive.
  def pid_state(pid)
    File.read("/proc/#{pid}/stat").rpartition(') ').last.split(' ', 2).first
  rescue Errno::ENOENT, Errno::ESRCH
    nil
  end

  def await_pid_states(pids, states, seconds: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    observed = {}
    loop do
      observed = pids.to_h { |pid| [pid, pid_state(pid)] }
      break if observed.values.all? { |state| states.include?(state) }
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.01
    end
    observed
  end

  # Our own child is wait-able, so this waits on the event itself, bounded.
  def await_child_exit(pid, seconds: 5)
    Timeout.timeout(seconds) { Process.waitpid(pid) }
    true
  rescue Timeout::Error
    false
  rescue Errno::ECHILD
    true
  end

  # Bounded wait on a real observable; unlike await_condition its failure is a nil RETURN rather
  # than a boolean, for waits whose observable is a value (a port, a pid list, a survivor list).
  def await_value(seconds)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    loop do
      value = yield
      return value if value
      return nil if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.01
    end
  end

  # Bounded wait on a real observable; unlike a sleep, it returns the instant the
  # condition holds and its failure is the assertion's, not a timeout's.
  def await_condition(seconds)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    loop do
      return true if yield
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.01
    end
  end

  # A real spawned master: it binds, forks its own workers and supervises them, and
  # reports the bound port and the child pids to us through a pipe.
  def spawn_master(worker_processes)
    reader, writer = IO.pipe
    master_pid = fork do
      reader.close
      Process.setproctitle('takagi-worker-tcp-spec-master')
      server = Takagi::Server::Tcp.new(port: 0, worker_processes: worker_processes)
      Thread.new do
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
        while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
          pids = server.worker_pids
          break if pids && pids.size == worker_processes

          sleep 0.01
        end
        port = server.instance_variable_get(:@server).addr[1]
        writer.puts "#{port} #{(server.worker_pids || []).join(' ')}"
        writer.close
      end
      server.run!
      exit!(0)
    end
    writer.close
    line = reader.gets
    reader.close
    port, *pids = line.to_s.split
    [master_pid, port.to_i, pids.map(&:to_i)]
  end

  def kill_quietly(pid, signal = 'KILL')
    Process.kill(signal, pid)
  rescue Errno::ESRCH
    nil
  end

  def clean_up_processes(master_pid, pids)
    Array(pids).each do |pid|
      kill_quietly(pid)
      Process.waitpid(pid, Process::WNOHANG)
    rescue Errno::ECHILD, Errno::ESRCH
      nil
    end
    return unless master_pid

    kill_quietly(master_pid)
    Process.waitpid(master_pid, Process::WNOHANG)
  rescue Errno::ECHILD, Errno::ESRCH
    nil
  end

  def kill_and_reap(pid)
    return unless pid

    kill_quietly(pid)
    Process.waitpid(pid)
  rescue Errno::ECHILD, Errno::ESRCH
    nil
  end

  def worker_title(pid)
    File.read("/proc/#{pid}/cmdline").split("\0").first
  rescue Errno::ENOENT, Errno::ESRCH
    nil
  end

  # /proc/<pid>/stat is "<pid> (<comm>) <state> <ppid> ...": after the closing parenthesis the
  # state comes first, so the parent link is the SECOND field.
  def ppid_of(pid)
    File.read("/proc/#{pid}/stat").rpartition(') ').last.split(' ', 3)[1].to_i
  rescue Errno::ENOENT, Errno::ESRCH
    nil
  end

  # The master's LIVE TCP worker children: the kernel's own parent link plus the
  # child's own title. A dead (zombie) child has an empty cmdline, so a corpse never
  # counts as a child here - which is what makes "every child is gone" observable.
  def worker_children_of(parent_pid)
    Dir.glob('/proc/[0-9]*/stat').filter_map do |path|
      pid = File.basename(File.dirname(path)).to_i
      next unless ppid_of(pid) == parent_pid
      next unless worker_title(pid).to_s.start_with?('takagi-worker-')

      pid
    rescue Errno::ENOENT, Errno::ESRCH
      nil
    end
  end

  # Reports what the server logs through the master's pipe, so a spec asserts on the
  # death line itself instead of on a timing. debug/info are dropped on purpose: the
  # accept loop logs per connection and would flood the pipe.
  class RecordingLogger
    def initialize(writer)
      @writer = writer
    end

    def info(_message); end

    def debug(_message); end

    def warn(message)
      @writer.puts "WARN #{message}"
    end

    def error(message)
      @writer.puts "ERROR #{message}"
    end
  end

  # The master's report channel. Every line is kept, so a line that already arrived is
  # never lost, and awaiting one is a bounded wait on a real event - never a sleep.
  class Report
    def initialize(io)
      @io = io
      @lines = []
    end

    attr_reader :lines

    def await(seconds: 10)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      loop do
        hit = @lines.find { |line| yield(line) }
        return hit if hit

        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return nil if remaining <= 0
        return nil unless @io.wait_readable(remaining)

        line = @io.gets
        return nil if line.nil?

        @lines << line.chomp
      end
    end

    def close
      @io.close unless @io.closed?
    end
  end

  # A spawned master that reports its own supervision state over a pipe, line by line:
  #   PIDS <port> <pid>...  whenever the server's own worker_pids changes
  #   WARN/ERROR <message>  what the server logs
  #   DONE closed=<bool> shutdown_called=<bool>  once run! has returned
  # A spec process cannot read a forked master's memory, so this is how the server's
  # own state is observed from outside without guessing at timings.
  def spawn_reporting_master(worker_processes)
    reader, writer = IO.pipe
    master_pid = fork do
      reader.close
      Process.setproctitle('takagi-worker-tcp-spec-supervisor')
      server = Takagi::Server::Tcp.new(port: 0, worker_processes: worker_processes,
                                       logger: RecordingLogger.new(writer))
      Thread.new do
        port = server.instance_variable_get(:@server).addr[1]
        last = nil
        until server.instance_variable_get(:@shutdown_called)
          # Compare the RENDERED line, never the array: Array() hands back the server's
          # own worker_pids object, so remembering it would alias the array the master
          # appends to - and a first read landing between @worker_pids = [] and the
          # forks would freeze an empty "already seen" snapshot and report nothing.
          line = "PIDS #{port} #{Array(server.worker_pids).join(' ')}"
          if line != last
            writer.puts line
            last = line
          end
          sleep 0.005
        end
      end
      server.run!
      socket = server.instance_variable_get(:@server)
      writer.puts "DONE closed=#{socket.closed?} shutdown_called=#{server.instance_variable_get(:@shutdown_called)}"
      writer.close
      exit!(0)
    end
    writer.close
    [master_pid, Report.new(reader)]
  end

  # Records what the server tells the operator, so the boot line can be asserted.
  class BootLog
    def initialize
      @lines = []
    end

    attr_reader :lines

    def info(message)
      @lines << message
    end

    def debug(_message); end

    def warn(message)
      @lines << message
    end

    def error(message)
      @lines << message
    end
  end

  # ROW 7: accepted-connection accounting is per SERVING PROCESS, so the spec has to
  # attribute each outcome to the worker that produced it. Every line this logger records
  # carries the pid that wrote it (the master or a forked child), a reader thread drains
  # the pipe so a chatty child can never block on it, and awaiting a line is a bounded
  # wait on a real event rather than a sleep. The per-poll accept chatter is dropped.
  class PidLog
    def initialize
      @reader, @writer = IO.pipe
      @writer.sync = true
      @lines = []
      @mutex = Mutex.new
      @thread = Thread.new do
        while (line = @reader.gets)
          @mutex.synchronize { @lines << line.chomp }
        end
      end
    end

    def info(message); record('INFO', message); end

    def warn(message); record('WARN', message); end

    def error(message); record('ERROR', message); end

    def debug(message)
      return if message == 'Waiting for client connection...'

      record('DEBUG', message)
    end

    def record(level, message)
      @writer.puts "#{Process.pid} #{level} #{message}"
    rescue Errno::EPIPE, IOError
      nil
    end

    def lines
      @mutex.synchronize { @lines.dup }
    end

    def await_line(seconds: 5)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      loop do
        hit = lines.find { |line| yield(line) }
        return hit if hit
        return nil if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep 0.01
      end
    end

    def close
      @writer.close unless @writer.closed?
      @thread.join(1)
      @thread.kill if @thread.alive?
      @reader.close unless @reader.closed?
    end
  end

  # What a worker did with one connection, read off the socket itself: a worker that
  # refuses closes the connection before it writes anything, so the client sees EOF, and
  # a served one has the server's CSM pending. MSG_PEEK reads without consuming, so a
  # served socket stays correctly framed for its own real exchange afterwards. The EOF
  # return of `recv_nonblock(..., exception: false)` is version-dependent: "" on Ruby
  # <= 3.3 and nil on Ruby 3.4+, so both count as refused.
  def connection_outcome(socket, seconds: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    loop do
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return :timeout if remaining <= 0
      next unless socket.wait_readable(remaining)

      case socket.recv_nonblock(1, Socket::MSG_PEEK, exception: false)
      when nil, '' then return :refused
      when :wait_readable then next
      else return :served
      end
    end
  rescue Errno::ECONNRESET, Errno::ENOTCONN, IOError
    :refused
  end

  # A served connection answers a real CoAP exchange; a refused one has nothing to say.
  def served_over_tcp(socket)
    socket.write(ping_frame)
    raw = read_tcp_message(socket)
    raw && Takagi::Message::Inbound.new(raw, transport: :tcp)
  rescue Errno::EPIPE, Errno::ECONNRESET, IOError
    nil
  end

  # A worker-pid list whose #each runs a hook once, right after the pass has looked
  # at the first pid. That makes "the pass is inside its iteration" an event a spec
  # can synchronize on, instead of racing a microsecond-wide window.
  class WorkerReapInterlock < Array
    def initialize(items, hook)
      super(items)
      @hook = hook
      @fired = false
    end

    def each
      super do |pid|
        yield pid
        next if @fired

        @fired = true
        @hook.call
      end
    end
  end

  # The public surface the consumed-status hazard needs: run! on a thread while
  # shutdown! stays reachable from the caller, with the pass caught mid-iteration. The pid
  # list and the pass itself live in the cluster now, so the interlock wraps the cluster's
  # own pid list through a singleton `spawn_workers`.
  def interlock_cluster_spawn!(cluster, interlock)
    original = Takagi::Server::Cluster.instance_method(:spawn_workers).bind(cluster)
    cluster.define_singleton_method(:spawn_workers) do
      original.call
      @worker_pids = WorkerReapInterlock.new(@worker_pids, interlock)
    end
  end

  it 'declares a worker_processes keyword on initialize' do
    parameters = Takagi::Server::Tcp.instance_method(:initialize).parameters
    expect(parameters).to include(%i[key worker_processes])
  end

  it 'cannot fork when worker_processes is the default single process' do
    default_server = Takagi::Server::Tcp.new(port: 0)
    explicit_one = Takagi::Server::Tcp.new(port: 0, worker_processes: 1)

    expect(default_server.cluster.forking?).to be(false)
    expect(explicit_one.cluster.forking?).to be(false)
  ensure
    default_server&.shutdown!
    explicit_one&.shutdown!
  end

  it 'serves connections in-process and starts no child for worker_processes: 1' do
    server = Takagi::Server::Tcp.new(port: 0, worker_processes: 1)
    runner = Thread.new { server.run! }
    response = ping_over_tcp(bound_port(server))

    expect(response.payload).to include('Pong')
    expect(server.worker_pids).to be_nil
    # No child of this process exists at all: nothing was forked for this server.
    expect { Process.waitpid(-1, Process::WNOHANG) }.to raise_error(Errno::ECHILD)
  ensure
    server&.shutdown!
    runner&.join(5)
  end

  # PROOF (fails on the pre-change tree): the payload carried the requested 0 while the
  # socket held the real port (36981 vs 0 in the recorded pre-change probe), so neither
  # the hook nor the boot log could be asserted against.
  it 'reports the real bound port in the :server_starting payload and the boot log on port: 0' do
    queue = Queue.new
    handler = Takagi::Hooks.subscribe(:server_starting) { |payload| queue << payload }
    logger = BootLog.new
    server = Takagi::Server::Tcp.new(port: 0, logger: logger)
    real_port = bound_port(server)
    runner = Thread.new { server.run! }

    payload = Timeout.timeout(5) { queue.pop }

    expect(real_port).to be_positive
    expect(payload[:protocol]).to eq(:tcp)
    expect(payload[:port]).to eq(real_port)
    expect(logger.lines).to include("Starting Takagi TCP server on port #{real_port}")
    # The reported port is the one really listening, which is what lets a caller or a
    # test connect to it instead of racing find_free_port.
    expect { TCPSocket.new('127.0.0.1', payload[:port]).close }.not_to raise_error
  ensure
    Takagi::Hooks.unsubscribe(:server_starting, handler)
    server&.shutdown!
    runner&.join(5)
  end

  it 'forks worker_processes children that serve the inherited listening socket' do
    server = Takagi::Server::Tcp.new(port: 0, worker_processes: 3)
    pids = []
    begin
      server.cluster.send(:spawn_workers)
      pids = server.worker_pids.dup

      expect(pids.size).to eq(3)
      pids.each_with_index do |pid, index|
        expect(Process.kill(0, pid)).to eq(1)
        expect(await_worker_title(pid, "takagi-worker-#{index}"))
          .to eq("takagi-worker-#{index}")
      end

      response = ping_over_tcp(bound_port(server))
      expect(response.payload).to include('Pong')

      server.shutdown!

      pids.each do |pid|
        # Wait first: kill(0) succeeds on a zombie, an immediate ESRCH could pass
        # for the wrong reason. The master already reaped these.
        expect { Process.waitpid(pid) }.to raise_error(Errno::ECHILD)
        expect { Process.kill(0, pid) }.to raise_error(Errno::ESRCH)
      end
    ensure
      pids.each do |pid|
        Process.kill('KILL', pid)
      rescue Errno::ESRCH
        nil
      end
      server.shutdown!
    end
  end

  it 'stops the master and every child inside the deadline when the master gets SIGTERM' do
    master_pid, port, pids = spawn_master(3)
    expect(pids.size).to eq(3)
    expect(ping_over_tcp(port).payload).to include('Pong')

    Process.kill('TERM', master_pid)

    # Wait for the master first: it is the children's parent, and it reaps them in
    # terminate_workers before it exits. Only after that does an absent /proc entry
    # prove each child terminated rather than linger as a zombie.
    expect(await_child_exit(master_pid)).to be(true)
    # The master reaped them in terminate_workers before it exited, so they are gone
    # already: no /proc entry left, and kill(0) - which would still succeed on a
    # zombie - is ESRCH for every child.
    expect(pids.map { |pid| pid_state(pid) }).to eq([nil] * pids.size)
    pids.each { |pid| expect { Process.kill(0, pid) }.to raise_error(Errno::ESRCH) }
    expect { Process.kill(0, master_pid) }.to raise_error(Errno::ESRCH)
  ensure
    clean_up_processes(master_pid, pids)
  end

  it 'lets the children exit on their own when the master is SIGKILLed' do
    master_pid, _port, pids = spawn_master(2)
    expect(pids.size).to eq(2)

    Process.kill('KILL', master_pid)
    expect(await_child_exit(master_pid)).to be(true)

    # Nothing is left to reap these: they must notice the missing master through the parent-death
    # guard the cluster armed them with - the master pid captured BEFORE the fork, never a parent
    # pid the child reads for itself after it. 'Z' counts as exited - the system reaper owns the
    # corpse once the parent is gone; what matters is that serving stopped.
    states = await_pid_states(pids, [nil, 'Z'])
    expect(states.values - [nil, 'Z']).to be_empty
  ensure
    clean_up_processes(master_pid, pids)
  end

  # ROW 7 (unified-cluster): the same parent-death path, FORCED instead of raced - row 34 proved it
  # with a probe outside the suite, and this is the promoted form. ONE forced interleaving: the
  # master forks its children with a `fork_worker` hook installed BEFORE `run!` reaches the fork,
  # so the SIGSTOP of each just-forked child is ARMED BEFORE THE TRIGGER. Every counted attempt is
  # PROVEN from /proc before the master is killed - every child must be state 'T', still parented
  # to the master, and still carrying the MASTER's cmdline, which proves `Process.setproctitle`
  # (the child's first statement, before the arming one) never ran. An attempt whose STOP lost the
  # race is DISCARDED, never counted. Returns :discarded, or [survivors, port] for a counted
  # attempt: the children that outlived the master by the stated deadline, and the port they
  # inherited from it.
  def forced_orphan_attempt(master_title, workers: 2, proof_seconds: 2.0, survivor_seconds: 2.0)
    reader, writer = IO.pipe
    master_pid = fork do
      reader.close
      Process.setproctitle(master_title)
      server = Takagi::Server::Tcp.new(port: 0, worker_processes: workers)
      cluster = server.cluster
      original = cluster.method(:fork_worker)
      # The SIGSTOP is issued by the MASTER the instant the fork returns, so the child is frozen in
      # the parent branch before it can run its first statement. The stopper is a closure, because
      # inside the singleton method `self` is the cluster, not this example.
      stopper = lambda do |pid|
        Process.kill('STOP', pid)
      rescue Errno::ESRCH
        nil
      end
      cluster.define_singleton_method(:fork_worker) do |index|
        pid = original.call(index)
        stopper.call(pid)
        pid
      end
      writer.puts "PORT #{bound_port(server)}"
      writer.flush
      server.run!
      exit!(0)
    end
    writer.close

    port = await_value(10) do
      next nil unless reader.wait_readable(0.2)

      line = reader.gets
      line && line[/\APORT (\d+)/, 1]&.to_i
    end
    raise 'the forked master never reported its port' if port.nil?

    proof = await_value(proof_seconds) do
      kids = worker_children_of(master_pid)
      next nil unless kids.size == workers

      fields = kids.map { |pid| [pid, pid_state(pid), ppid_of(pid), worker_title(pid)] }
      # A child that already carries its own title has armed itself, so this STOP lost the race.
      next :lost if fields.any? { |_pid, _state, _ppid, title| title != master_title }

      fields.all? { |_pid, state, ppid, _title| state == 'T' && ppid == master_pid } ? kids : nil
    end

    if proof.nil? || proof == :lost
      discard_orphan_attempt(master_pid)
      return :discarded
    end

    # THE TRIGGER: the master dies while its children are frozen BEFORE their first statement, so
    # whatever they do next is decided by the value the cluster armed them with.
    Process.kill('KILL', master_pid)
    Process.waitpid(master_pid)
    proof.each { |pid| kill_quietly(pid, 'CONT') }

    survivors = await_value(survivor_seconds) do
      alive = proof.reject { |pid| [nil, 'Z'].include?(pid_state(pid)) }
      alive.empty? ? [] : nil
    end || proof.dup
    survivors.each { |pid| kill_quietly(pid) }
    await_value(2) { proof.all? { |pid| [nil, 'Z'].include?(pid_state(pid)) } ? true : nil }
    [survivors, port]
  ensure
    reader&.close
  end

  # A discarded attempt still forked children, and they must end BEFORE the master, or the master's
  # death reparents them and they keep serving on the inherited listener.
  def discard_orphan_attempt(master_pid)
    worker_children_of(master_pid).each do |pid|
      kill_quietly(pid, 'CONT')
      kill_quietly(pid)
    end
    kill_quietly(master_pid)
    Process.waitpid(master_pid)
  rescue Errno::ECHILD, Errno::ESRCH
    nil
  end

  # PROOF (row 7): the headline GUARD above only proves that children ALREADY ARMED notice a dead
  # master; this forces the harder interleaving - the master dies BEFORE a child runs at all, which
  # is what the pre-fork capture exists for. Discriminating mutation: arming the cluster with
  # `Process.ppid` instead of the captured master pid (`Cluster#reset_child_state`) turns every
  # counted attempt into a child that adopts the reaper and holds the listener forever.
  # "repetitions (>= 10) for anything timing-shaped": the SIGSTOP must beat a child's first
  # statement, so the choreography is repeated and every repetition is proven pre-arm.
  it 'leaves no child holding the listener when the master dies before a child ever runs' do
    master_title = 'takagi-worker-tcp-spec-orphan-master'
    counted = 0
    discarded = 0
    attempts = 0
    survivors = []

    while counted < 10 && attempts < 200
      attempts += 1
      outcome = forced_orphan_attempt(master_title)
      if outcome == :discarded
        discarded += 1
        next
      end

      found, = outcome
      counted += 1
      survivors.concat(found)
    end

    # The choreography must really have happened, or a green would prove nothing about the race.
    expect(counted).to eq(10),
                       "only #{counted} of 10 forced interleavings were PROVEN in #{attempts} " \
                       "attempts (#{discarded} discarded)"
    expect(survivors).to be_empty,
                          "#{survivors.size} child(ren) outlived the master that forked them: " \
                          "#{survivors.inspect}"
  end

  it 'terminates the workers before it closes the listening socket' do
    pids = []
    server = Takagi::Server::Tcp.new(port: 0, worker_processes: 2)
    server.cluster.send(:spawn_workers)
    pids = server.worker_pids.dup
    listener = server.instance_variable_get(:@server)
    cluster = server.cluster
    original = Takagi::Server::Cluster.instance_method(:terminate_workers).bind(cluster)
    closed_while_terminating = nil
    cluster.define_singleton_method(:terminate_workers) do
      closed_while_terminating = listener.closed?
      original.call
    end

    server.shutdown!

    # Terminate-before-close, the inverse of the UDP race REVIEW.md:89 records.
    expect(closed_while_terminating).to be(false)
    expect(listener).to be_closed
  ensure
    clean_up_processes(nil, pids)
    server&.shutdown!
  end

  it 'escalates to KILL inside a bounded per-batch deadline when workers ignore TERM' do
    pids = []
    server = Takagi::Server::Tcp.new(port: 0, worker_processes: 3)
    server.cluster.send(:spawn_workers)
    pids = server.worker_pids.dup
    expect(pids.size).to eq(3)

    # A stopped process cannot honour TERM: the signal stays pending until it is
    # continued, so only KILL can end it. This is a deliberately TERM-deaf worker.
    pids.each { |pid| Process.kill('STOP', pid) }
    expect(await_pid_states(pids, ['T']).values).to eq(%w[T T T])

    bound = Takagi::Server::Cluster::WORKER_TERM_TIMEOUT + 1.0
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    expect { Timeout.timeout(bound) { server.cluster.send(:terminate_workers) } }.not_to raise_error
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    expect(elapsed).to be <= bound
    expect(elapsed).to be >= (Takagi::Server::Cluster::WORKER_TERM_TIMEOUT * 0.5)
    expect(pids.map { |pid| pid_state(pid) }).to eq([nil] * pids.size)
  ensure
    clean_up_processes(nil, pids)
    server&.shutdown!
  end

  it 'reaps a SIGKILLed child, respawns it, logs the death once with its replacement, and keeps serving' do
    master_pid, report = spawn_reporting_master(3)
    pids = []
    replacement = nil
    restored = []
    begin
      complete = report.await(seconds: 10) { |line| line.match?(/\APIDS \d+ \d+ \d+ \d+\z/) }
      expect(complete).not_to be_nil, "the master never reported three worker_pids; saw #{report.lines.inspect}"
      _tag, port_s, *pid_s = complete.split
      port = port_s.to_i
      pids = pid_s.map(&:to_i)
      expect(ping_over_tcp(port).payload).to include('Pong')

      victim = pids.first
      Process.kill('KILL', victim)

      # The EVENT, not a timeout: the server's own worker_pids back at the configured
      # count, with a pid that did not exist before. Bounded wait on that report line.
      predicate = lambda do |line|
        fields = line.split
        next false unless fields.first == 'PIDS' && fields[1].to_i == port

        candidate = fields.drop(2).map(&:to_i)
        next false unless candidate.size == 3 && candidate != pids

        restored = candidate
        true
      end
      report.await(seconds: 10, &predicate)
      replacement = (restored - pids).first
      expect(replacement).not_to be_nil,
                              "the killed child was not replaced; reports: #{report.lines.inspect}"
      expect(restored.size).to eq(3)
      expect(restored).to include(*(pids - [victim]))
      # The replacement takes over the dead worker's index, so its title is truthful.
      expect(await_worker_title(replacement, "takagi-worker-#{pids.index(victim)}"))
        .to eq("takagi-worker-#{pids.index(victim)}")

      # The restored pool serves a real exchange, and no snapshot ever reported more
      # workers than the configured count.
      expect(ping_over_tcp(port).payload).to include('Pong')
      expect(report.lines.select { |line| line.start_with?('PIDS') }.map { |line| line.split.size })
        .to all(be <= 5)

      # One honest line per death: the dead pid, its status, its index and the pid that
      # replaced it - and never a second line for the same death.
      death = report.await(seconds: 10) { |line| line.include?("worker #{victim}") }
      expect(death).not_to be_nil, "no death line; saw #{report.lines.inspect}"
      expect(death).to include("worker #{victim} (index #{pids.index(victim)})")
      expect(death).to include('respawned as')
      expect(death).to include(replacement.to_s)
      expect(report.lines.count { |line| line.include?("worker #{victim}") }).to eq(1)

      # Teardown through the real surface: TERM the master and prove the master, the
      # replacement and its siblings are all gone rather than lingering.
      Process.kill('TERM', master_pid)
      expect(await_child_exit(master_pid)).to be(true)
      expect(restored.map { |pid| pid_state(pid) }).to eq([nil] * restored.size)
      expect { TCPSocket.new('127.0.0.1', port) }.to raise_error(Errno::ECONNREFUSED)
    ensure
      (pids + restored + [replacement]).compact.each { |pid| kill_quietly(pid) }
      kill_and_reap(master_pid)
      report&.close
    end
  end

  it 'ends supervision and runs shutdown! when every child is gone at once' do
    master_pid, report = spawn_reporting_master(3)
    pids = []
    begin
      complete = report.await(seconds: 10) { |line| line.match?(/\APIDS \d+ \d+ \d+ \d+\z/) }
      expect(complete).not_to be_nil, "the master never reported three worker_pids; saw #{report.lines.inspect}"
      _tag, port_s, *pid_s = complete.split
      port = port_s.to_i
      pids = pid_s.map(&:to_i)
      expect(pids.size).to eq(3)

      # Freeze the supervisor, then kill every child. With the master stopped it cannot
      # reap one and replace it before the next dies, so the pass that follows sees the
      # WHOLE worker set gone - exactly the failure this row must make loud.
      Process.kill('STOP', master_pid)
      expect(await_pid_states([master_pid], ['T']).values).to eq(['T'])

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
      killed = []
      loop do
        workers = worker_children_of(master_pid)
        workers.each do |pid|
          kill_quietly(pid)
          killed << pid
        end
        break if workers.empty?
        break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep 0.01
      end
      # The discovery and the kills must be real, or the rest of this example would
      # pass for the wrong reason: every reported child was found and is dead now.
      expect(killed).to include(*pids)
      expect(worker_children_of(master_pid)).to be_empty
      expect(await_pid_states(pids, [nil, 'Z']).values.uniq - [nil, 'Z']).to be_empty

      Process.kill('CONT', master_pid)

      # Observable: the master's own run! returns, with @shutdown_called true and its
      # listener closed - supervision ENDED by running shutdown!, rather than standing
      # over a port with no worker behind it.
      done = report.await(seconds: 10) { |line| line.start_with?('DONE ') }
      expect(done).not_to be_nil, "the supervision loop never ended; saw #{report.lines.inspect}"
      expect(done).to include('shutdown_called=true')
      expect(done).to include('closed=true')
      expect(report.lines).to include(a_string_matching(/\AERROR .*all workers are gone/))

      # The port is not silently held by a master with no workers: the master exits on
      # its own and the port refuses connections.
      expect(await_child_exit(master_pid)).to be(true)
      expect { TCPSocket.new('127.0.0.1', port) }.to raise_error(Errno::ECONNREFUSED)
    ensure
      pids.each { |pid| kill_quietly(pid) }
      kill_and_reap(master_pid)
      report&.close
    end
  end

  # GUARD (passes on the pre-change tree too, deliberately): pins the Must-NOT that
  # supervision never respawns once a shutdown has been requested - a future change
  # that moves the spawn ahead of the flag check would ship a child nobody stops.
  it 'does not respawn a dead child once a shutdown has been requested' do
    server = Takagi::Server::Tcp.new(port: 0, worker_processes: 2)
    server.cluster.send(:spawn_workers)
    pids = server.worker_pids.dup
    server.cluster.stop!
    Process.kill('KILL', pids.first)

    server.cluster.send(:supervise_workers)

    expect(server.worker_pids).to eq(pids)
  ensure
    server&.shutdown!
  end

  # PROOF (fails on the pre-change tree with Errno::ECHILD out of run!'s own thread):
  # the documented pattern runs run! on a thread while shutdown! stays reachable, and
  # terminate_workers reaps the children it empties out of @worker_pids. A pass already
  # inside its iteration then reaches a pid that reaper consumed.
  it 'treats a worker status consumed by a second reaper inside the pass as already consumed' do
    consumed = nil
    survivors = []
    replacement = nil
    server = Takagi::Server::Tcp.new(port: 0, worker_processes: 3)
    interlock = lambda do
      # The pass is at its first pid now. A real second reaper thread kills a child the
      # pass has not reached and consumes its status - what terminate_workers does when
      # a concurrent shutdown! lands inside a pass.
      if consumed.nil?
        victim = server.worker_pids[1]
        Process.kill('KILL', victim)
        Timeout.timeout(10) { Process.waitpid(victim) }
        consumed = victim
      end
    end
    interlock_cluster_spawn!(server.cluster, interlock)
    runner = Thread.new { server.run! }

    # The pass finished the moment it replaced the interlocked list with its own result:
    # the two surviving children, with the consumed one dropped. `consumed` is required
    # in the condition too, because before the first pass the list is nil - awaiting the
    # class alone could pass without a single pass having run.
    finished = await_condition(10) do
      consumed && !server.worker_pids.is_a?(WorkerReapInterlock) && server.worker_pids.size == 2
    end
    expect(finished).to be(true),
                       "the pass never returned with the consumed child dropped; " \
                       "consumed=#{consumed.inspect} worker_pids=#{server.worker_pids.inspect}"
    expect(consumed).to be_positive
    expect(runner).to be_alive

    # The supervisor keeps polling after surviving the consumed status: a worker killed
    # now is still replaced, one-for-one, so the fix does not end supervision.
    survivors = server.worker_pids
    Process.kill('KILL', survivors.last)
    expect(await_condition(10) { !(replacement = (server.worker_pids - survivors).first).nil? })
      .to be(true), "no replacement after the interlocked pass; worker_pids=#{server.worker_pids.inspect}"
    expect(replacement).to be_positive
    expect(server.worker_pids.size).to eq(survivors.size)
  ensure
    [*survivors, replacement].compact.each { |pid| kill_and_reap(pid) }
    server&.shutdown!
    # After the fix the runner is still polling and ends on shutdown!; before it, the
    # thread died of the very hazard this example pins, and the assertion above is that
    # record - so teardown must not re-raise it over the failure.
    begin
      runner&.join(5)
    rescue StandardError
      nil
    end
  end

  # PROOF (the pre-change tree rejects the keyword outright, so the pool cannot exist
  # there): a pool of one thread serves one connection at a time, and the connection
  # that finds it busy is QUEUED - accepted and counted, not refused - because the
  # per-worker cap has not been reached.
  it 'serves one connection at a time with worker_threads: 1 and queues the next instead of refusing it' do
    server = Takagi::Server::Tcp.new(port: 0, worker_threads: 1, max_connections: 5)
    runner = Thread.new { server.run! }
    port = bound_port(server)
    first = TCPSocket.new('127.0.0.1', port)
    expect(ping_on(first).payload).to include('Pong')

    # The first connection keeps the single pool thread: its handler loops over that
    # connection for as long as the client holds it open, so the second socket lands in
    # the queue. The queue and the accepted-connection count are the observables.
    second = TCPSocket.new('127.0.0.1', port)
    second.write(ping_frame)
    expect(await_condition(5) { pool_of(server).size == 1 }).to be(true)
    expect(server.instance_variable_get(:@active_connections)).to eq(2)
    # Not refused: the server sends nothing (not even its CSM, which a handler emits)
    # while the single thread is busy. A refused connection gets EOF instead, and a
    # server without a pool answers this socket immediately - so this discriminates.
    expect(second.wait_readable(0.2)).to be_nil

    # Freeing the thread serves the queued connection, which is what "queued, not
    # refused" means for the client.
    first.close
    expect(ping_on(second).payload).to include('Pong')
  ensure
    close_quietly(first, second)
    server&.shutdown!
    runner&.join(5)
  end

  # PROOF (same reason): with the pool on, a full pool queues while the per-worker cap is
  # not reached, and the refusal path is still exactly today's - AT the cap.
  it 'queues at a full pool below the cap and still refuses at the cap' do
    server = Takagi::Server::Tcp.new(port: 0, worker_threads: 2, max_connections: 3)
    runner = Thread.new { server.run! }
    port = bound_port(server)
    busy = open_connections(port, 2)
    busy.each { |socket| expect(ping_on(socket).payload).to include('Pong') }

    # Every pool thread is busy and the cap (3) is not reached: queue it.
    queued = TCPSocket.new('127.0.0.1', port)
    queued.write(ping_frame)
    expect(await_condition(5) { pool_of(server).size == 1 }).to be(true)
    expect(server.instance_variable_get(:@active_connections)).to eq(3)
    expect(queued.wait_readable(0.2)).to be_nil

    # One more connection reaches the cap: the refusal is unchanged - closed with no CSM,
    # so the client reads EOF.
    refused = TCPSocket.new('127.0.0.1', port)
    expect(refused.wait_readable(5)).to be_truthy
    expect(refused.read).to eq('')

    # The queued connection was never lost: freeing one pool thread serves it.
    busy.first.close
    expect(ping_on(queued).payload).to include('Pong')
  ensure
    close_quietly(*busy, queued, refused)
    server&.shutdown!
    runner&.join(5)
  end

  # PROOF (no pool exists on the pre-change tree, so this cannot pass by accident): no
  # handler thread outlives shutdown!, even with both connections still open.
  it 'leaves no handler thread behind after shutdown! while connections are still open' do
    server = Takagi::Server::Tcp.new(port: 0, worker_threads: 2, max_connections: 5)
    runner = Thread.new { server.run! }
    port = bound_port(server)
    sockets = open_connections(port, 2)
    sockets.each { |socket| expect(ping_on(socket).payload).to include('Pong') }

    pool_threads = server.instance_variable_get(:@pool_threads)
    expect(pool_threads.size).to eq(2)
    expect(pool_threads.map(&:alive?)).to eq([true, true])

    server.shutdown!

    expect(await_condition(5) { pool_threads.none?(&:alive?) }).to be(true)
    expect(Thread.list.select { |thread| thread.alive? && thread.name.to_s.start_with?('takagi-tcp-pool-') })
      .to be_empty
  ensure
    close_quietly(*sockets)
    server&.shutdown!
    runner&.join(5)
  end

  # PROOF on the pre-change tree (the keyword is rejected there); GUARD for the behaviour
  # it asserts, which is today's connection-thread model by construction. This is the
  # row's hard boundary: an unset count starts no pool and no extra thread.
  it 'starts no pool and keeps the connection-thread model when worker_threads is unset' do
    server = Takagi::Server::Tcp.new(port: 0)
    runner = Thread.new { server.run! }
    port = bound_port(server)
    first = TCPSocket.new('127.0.0.1', port)
    expect(ping_on(first).payload).to include('Pong')

    expect(pool_of(server)).to be_nil
    expect(server.instance_variable_get(:@pool_threads)).to be_nil

    # The second connection is served while the first is still open: with no pool, every
    # connection carries its own handler thread, which is exactly what a pool of one
    # would not do.
    second = TCPSocket.new('127.0.0.1', port)
    expect(ping_on(second).payload).to include('Pong')
    expect(Thread.list.count { |thread| thread.name.to_s.start_with?('takagi-tcp-pool-') }).to eq(0)
  ensure
    close_quietly(first, second)
    server&.shutdown!
    runner&.join(5)
  end

  # PROOF/GUARD pair, same labelling as above: a count at or above the cap cannot bound
  # anything the cap does not already bound, so it keeps today's model too.
  it 'keeps the connection-thread model when worker_threads is at or above max_connections' do
    server = Takagi::Server::Tcp.new(port: 0, worker_threads: 3, max_connections: 3)
    runner = Thread.new { server.run! }
    port = bound_port(server)
    first = TCPSocket.new('127.0.0.1', port)
    expect(ping_on(first).payload).to include('Pong')

    expect(server.send(:pooled?)).to be(false)
    expect(pool_of(server)).to be_nil

    second = TCPSocket.new('127.0.0.1', port)
    expect(ping_on(second).payload).to include('Pong')
    expect(Thread.list.count { |thread| thread.name.to_s.start_with?('takagi-tcp-pool-') }).to eq(0)
  ensure
    close_quietly(first, second)
    server&.shutdown!
    runner&.join(5)
  end

  # PROOF (the pre-change tree drops the per-protocol value at the `:udp` gate, and the
  # keyword it would need does not exist): a written `protocol_settings[:tcp][:threads]`
  # reaches the TCP server, and a configuration that only carries the global default does
  # not put a pool under TCP.
  describe 'the :tcp worker_threads pass-through' do
    let(:lifecycle) { Class.new { include Takagi::Base::ServerLifecycle }.new }

    def build_tcp_server(protocol_settings, threads)
      allow(Takagi.config).to receive_messages(protocol_settings: protocol_settings, threads: threads,
                                               processes: 1, max_connections: nil)
      lifecycle.send(:build_servers, [:tcp], 0).first
    end

    it 'carries a per-protocol threads count to the TCP handler pool' do
      server = build_tcp_server({ tcp: { threads: 3 } }, 1)

      expect(server.instance_variable_get(:@worker_threads)).to eq(3)
      expect(server.send(:pooled?)).to be(true)
    ensure
      server&.instance_variable_get(:@server)&.close
    end

    it 'leaves the pool unset when only the global threads default applies' do
      server = build_tcp_server({}, 1)

      expect(server.instance_variable_get(:@worker_threads)).to be_nil
      expect(server.send(:pooled?)).to be(false)
    ensure
      server&.instance_variable_get(:@server)&.close
    end
  end

  # A connection a worker SERVED: it answers a real ping, and the pid that logged its
  # accept line is the worker that accepted it.
  def served_connection(port, log, opened)
    socket = TCPSocket.new('127.0.0.1', port)
    opened << socket
    expect(served_over_tcp(socket)&.payload).to include('Pong')
    line = log.await_line { |l| l.include?('Client connected from') && l.include?(", #{socket.addr[1]}, ") }
    expect(line).not_to be_nil, "no accept line for client port #{socket.addr[1]}; log=#{log.lines.inspect}"
    [socket, line.split(' ', 2).first.to_i]
  end

  # A connection a worker REFUSED: EOF to the client, and the refusal warning is written by
  # the worker that refused - the same process that took the connection.
  def refused_connection(port, log, max_connections, refusing_pid, opened)
    socket = TCPSocket.new('127.0.0.1', port)
    opened << socket
    expect(connection_outcome(socket)).to eq(:refused)
    line = log.await_line do |l|
      l.start_with?("#{refusing_pid} ") && l.include?("TCP connection limit (#{max_connections}) reached")
    end
    expect(line).not_to be_nil, "no refusal line from #{refusing_pid}; log=#{log.lines.inspect}"
    line.split(' ', 2).first.to_i
  end

  # ROW 7: the per-worker rule, measured through real sockets with the kernel's own
  # distribution PINNED instead of raced. A burst of connections at two workers is NOT a
  # fair test of a per-worker cap: whichever worker happens to drain the shared listen queue
  # can refuse a connection another idle worker could have served, so the burst count is not
  # an observable of the rule (it measured 1 here in a full-suite run). Here only ONE worker
  # is ever able to accept - the other is SIGSTOPped - so every outcome is decided and
  # attributable: the running worker serves up to ITS OWN cap, refuses the next connection
  # in its own warning, and after the roles are swapped the same server holds BOTH caps at
  # once, which is the effective ceiling `worker_processes x max_connections` that one
  # shared counter could never reach.
  def assert_worker_cap(worker_processes:, max_connections:)
    log = PidLog.new
    server = Takagi::Server::Tcp.new(port: 0, worker_processes: worker_processes,
                                     max_connections: max_connections, logger: log)
    opened = []
    stopped = []
    begin
      server.cluster.send(:spawn_workers)
      pids = server.worker_pids.dup
      expect(pids.size).to eq(worker_processes)
      first, second = pids
      port = bound_port(server)

      Process.kill('STOP', second)
      stopped << second
      served_first = Array.new(max_connections) { served_connection(port, log, opened) }
      expect(served_first.map(&:last)).to eq([first] * max_connections)
      expect(refused_connection(port, log, max_connections, first, opened)).to eq(first)

      Process.kill('STOP', first)
      stopped << first
      Process.kill('CONT', second)
      stopped.delete(second)
      served_second = Array.new(max_connections) { served_connection(port, log, opened) }
      expect(served_second.map(&:last)).to eq([second] * max_connections)
      expect(refused_connection(port, log, max_connections, second, opened)).to eq(second)

      # Every one of those connections is still open and answered: each worker held its own
      # cap at the same time, in the same server.
      expect((served_first + served_second).map(&:last).uniq).to eq(pids)
      expect(served_first.size + served_second.size).to eq(worker_processes * max_connections)

      # The accounting is per serving process and never the master's: it counted nothing
      # while its children held two caps' worth of connections.
      expect(server.instance_variable_get(:@active_connections)).to eq(0)

      # Capacity comes back per worker: with every served connection closed a fresh one is
      # served again, so release_connection ran in the process that took the slot.
      close_quietly(*(served_first + served_second).map(&:first))
      Process.kill('CONT', first)
      stopped.delete(first)
      reopened = await_condition(10) do
        candidate = TCPSocket.new('127.0.0.1', port)
        opened << candidate
        served_over_tcp(candidate) ? true : close_quietly(candidate)
      end
      expect(reopened).to be(true)
    ensure
      stopped.each do |pid|
        Process.kill('CONT', pid)
      rescue Errno::ESRCH
        nil
      end
      close_quietly(*opened)
      server&.shutdown!
      log&.close
    end
  end

  # ROW 7 PROOF against the pre-plan bytes - there is no `worker_processes` keyword to build
  # this server with, so the example cannot pass there; on the row-6 tree, where the
  # per-worker accounting already exists, it is a GUARD that pins the rule the option now
  # documents. The discriminating negative is in the evidence file: with the accounting
  # mutated into ONE SHARED COUNTER both examples FAIL, and this one measures two served
  # connections where a shared cap of 1 can only ever produce one.
  it 'caps accepted connections per worker: each worker serves one and refuses the second under max_connections: 1' do
    assert_worker_cap(worker_processes: 2, max_connections: 1)
  end

  # Same PROOF/GUARD labelling; the second configuration pins the multiplication itself.
  it 'sets the effective ceiling of one server to worker_processes x max_connections' do
    assert_worker_cap(worker_processes: 2, max_connections: 2)
  end

  # ROW 15 GUARD: the frame helper must stay a pass-through, so a future example in this
  # file that sends anything larger than the ping cannot hang on the old double-framing.
  # On the pass-through this is an identity; on the helper's old body the 300-byte payload
  # comes out 320 bytes with a 0x00 Code byte (measured), so the example is red there.
  it 'keeps the frame helper a pass-through for a payload beyond the ping' do
    request = Takagi::Message::Outbound.new(
      code: 1, # GET
      payload: 'x' * 300,
      token: '12345678',
      options: { 11 => ['ping'] }, # Uri-Path
      transport: :tcp
    )
    frame = request.to_bytes(transport: :tcp)

    expect(encode_tcp_frame(frame)).to eq(frame)
  end

  # ROW 11: DISTRIBUTION across the children, pinned by a forced choreography instead of a
  # burst. With several children blocked in accept on the SAME inherited listener the
  # kernel decides which one wakes, so a burst ratio is not an observable of "every child
  # serves": row 7 measured the trap directly - its burst example passed 10/10 in
  # isolation and then read "expected 2 got 1" in a full-suite run. Here exactly ONE child
  # can accept at a time (its siblings are SIGSTOPped and their stop is awaited first), so
  # each exchange's owner is decided by the spec and named by the accepting child's OWN
  # log line. `spawn_workers` is called and `run!` never is, so the master runs no accept
  # loop at all: an answer can only have come from a child.
  it 'distributes connections across every child, pinned with a stopped worker' do
    log = PidLog.new
    server = Takagi::Server::Tcp.new(port: 0, worker_processes: 3, logger: log)
    opened = []
    stopped = []
    accepted_by = []
    begin
      server.cluster.send(:spawn_workers)
      pids = server.worker_pids.dup
      expect(pids.size).to eq(3)
      port = bound_port(server)

      pids.each_with_index do |pid, index|
        # This child takes its turn; every sibling is stopped, and the stop is awaited
        # before anything is attributed, because a STOPped process cannot accept.
        Process.kill('CONT', pid)
        expect(await_pid_states([pid], %w[S R D]).values).not_to eq(['T'])
        others = pids - [pid]
        others.each { |other| Process.kill('STOP', other) }
        stopped = others
        expect(await_pid_states(others, ['T']).values).to eq(['T'] * others.size)

        _socket, worker = served_connection(port, log, opened)
        accepted_by << worker
        expect(worker).to eq(pid)
        expect(await_worker_title(pid, "takagi-worker-#{index}"))
          .to eq("takagi-worker-#{index}")
      end

      # Every child took its turn, in the order the choreography forced: that is the
      # distribution itself, never a ratio read off a burst.
      expect(accepted_by).to eq(pids)
      expect(server.worker_pids).to eq(pids)
    ensure
      stopped.each do |pid|
        Process.kill('CONT', pid)
      rescue Errno::ESRCH
        nil
      end
      close_quietly(*opened)
      server&.shutdown!
      log&.close
    end
  end

  # ROW 17 (folded into this lane, which owns this spec file): `Watcher#stop` must tolerate
  # a watcher thread that has already finished. `Thread#wakeup` raises ThreadError
  # ("killed thread") on a finished thread - measured - so the old guard
  # `@thread&.wakeup if @thread&.alive?` lost the race whenever the watcher thread
  # terminated between the liveness check and the wakeup: the registered intermittent
  # full-suite failure of this file (ThreadError out of lib/takagi/observer/watcher.rb:38,
  # reached from tcp.rb's `@watcher.stop` during an example's teardown). The interleaving
  # is FORCED here rather than raced: `alive?` answers truthfully, and the watcher's own
  # loop is then handed the schedule so it finishes (it exits on its own once stop has set
  # @running = false) before stop reaches the wakeup.
  it 'tolerates a watcher thread that finished before the wakeup' do
    allow(Takagi::ObserveRegistry).to receive(:subscription_paths).and_return([])
    watcher = Takagi::Observer::Watcher.new(interval: 0.05)
    thread = watcher.start
    real_alive = thread.method(:alive?)
    thread.define_singleton_method(:alive?) do
      was_alive = real_alive.call
      thread.join(2) if was_alive
      was_alive
    end

    expect { watcher.stop }.not_to raise_error
    # The thread the wakeup was aimed at is genuinely finished, and stop left it that way.
    expect(real_alive.call).to be(false)
  ensure
    thread&.kill
  end
end
