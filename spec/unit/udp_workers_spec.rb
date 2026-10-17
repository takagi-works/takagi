# frozen_string_literal: true

# Plan row 2 (unified-cluster): the UDP server rides on Server::Cluster. These examples pin
# the row's own acceptance from the SERVER's state and from /proc - count 1 serving
# in-process with nothing forked, index-bearing transport-free titles, and the cluster's
# reap-and-replace applied to a socket this transport owns.
#
# Plan row 7 (unified-cluster) carries the techniques row 11 proved for TCP over to this
# transport: the orphan path is FORCED instead of raced (the SIGSTOP of every just-forked child
# is armed on the cluster BEFORE `run!` reaches the fork, and every counted attempt is proven
# pre-arm from /proc before the master is killed), the datagram distribution across the children
# is pinned by a stopped-siblings choreography rather than read off a burst, and every wait is
# bounded by a stated deadline.
RSpec.describe 'Takagi UDP server on the worker cluster (plan row 2)' do
  # A logger that records every level under one mutex, so a line written from the cluster's
  # supervision thread can be read from the example thread with a bounded wait.
  class UdpWorkersRecordingLogger
    def initialize
      @lines = []
      @mutex = Mutex.new
    end

    %i[debug info warn error].each do |level|
      define_method(level) do |message|
        @mutex.synchronize { @lines << "#{level}: #{message}" }
      end
    end

    def snapshot = @mutex.synchronize { @lines.dup }
  end

  def bound_port(server) = server.instance_variable_get(:@socket).addr[1]

  def pid_state(pid)
    File.read("/proc/#{pid}/stat").rpartition(') ').last.split(' ', 2).first
  rescue Errno::ENOENT, Errno::ESRCH
    nil
  end

  def cmdline_of(pid)
    File.read("/proc/#{pid}/cmdline").split("\0").first
  rescue Errno::ENOENT, Errno::ESRCH
    nil
  end

  # /proc/<pid>/stat is "<pid> (<comm>) <state> <ppid> ...", so the parent link is the field
  # after the state, which is why the parse resumes after the closing parenthesis.
  def ppid_of(pid)
    File.read("/proc/#{pid}/stat").rpartition(') ').last.split(' ', 3)[1].to_i
  rescue Errno::ENOENT, Errno::ESRCH
    nil
  end

  # The children a pid currently has, by the kernel's own parent link: a reaped or zombie child
  # has no /proc entry or no cmdline left, so a corpse never counts as a child here - which is
  # what makes "every child is gone" an observable rather than a guess.
  def children_of(parent_pid)
    Dir.glob('/proc/[0-9]*/stat').filter_map do |path|
      pid = File.basename(File.dirname(path)).to_i
      next nil unless ppid_of(pid) == parent_pid
      next nil unless cmdline_of(pid).to_s.start_with?('takagi-worker-')

      pid
    end
  end

  def kill_quietly(pid)
    Process.kill('KILL', pid)
  rescue Errno::ESRCH
    nil
  end

  def resume_quietly(pid, signal = 'CONT')
    Process.kill(signal, pid)
  rescue Errno::ESRCH
    nil
  end

  # Bounded wait on an observable: the block returns the value it is waiting for, or nil
  # until the deadline. Never a fixed pause.
  def await(seconds: 10)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    loop do
      value = yield
      return value if value
      return nil if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.01
    end
  end

  # A bounded read on a pipe: the parsed line the instant one arrives, nil at the stated
  # deadline. The wait is on the readable event, never on a fixed pause.
  def read_bounded(reader, seconds: 5)
    await(seconds: seconds) do
      next nil unless reader.wait_readable(0.2)

      reader.gets&.strip
    end
  end

  def await_worker_pids(server, count, seconds: 10)
    await(seconds: seconds) do
      list = server.worker_pids
      list && list.size == count ? list.dup : nil
    end
  end

  def await_replacement(server, previous, seconds: 10)
    await(seconds: seconds) do
      list = server.worker_pids
      list && list.size == previous.size && list != previous ? list.dup : nil
    end
  end

  def await_worker_title(pid, expected, seconds: 5)
    await(seconds: seconds) { title = cmdline_of(pid); title == expected ? title : nil }
  end

  def await_log_line(logger, seconds: 10, &predicate)
    await(seconds: seconds) { logger.snapshot.find { |line| predicate.call(line) } }
  end

  def gone?(pid) = [nil, 'Z'].include?(pid_state(pid))

  # A CoAP CON GET /ping with a token, the exchange spec/unit/udp_worker_spec.rb drives.
  def get_ping(message_id)
    [0x41, 0x01, (message_id >> 8) & 0xFF, message_id & 0xFF, 0x41, 0xB4, 0x70, 0x69, 0x6E, 0x67].pack('C*')
  end

  # Bounded exchange: resend inside the deadline, never sleep for a fixed amount.
  def exchange(port, seconds: 3.0)
    socket = UDPSocket.new
    socket.connect('127.0.0.1', port)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    message_id = 0x5100
    loop do
      socket.send(get_ping(message_id), 0)
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return nil if remaining <= 0

      return socket.recvfrom(4096).first if socket.wait_readable(remaining)

      message_id += 1
    end
  ensure
    socket&.close
  end

  it 'declares a worker_processes keyword on initialize' do
    expect(Takagi::Server::Udp.instance_method(:initialize).parameters).to include(%i[key worker_processes])
  end

  describe 'the adapter declaration the cluster supervises through' do
    it 'hands over the already-bound socket as a datagram unit of work with a drain deadline below the master batch deadline' do
      server = Takagi::Server::Udp.new(port: 0, worker_processes: 2, worker_threads: 2)
      adapter = server.send(:build_cluster_adapter)

      expect(adapter.fds).to eq([server.instance_variable_get(:@socket)])
      expect(adapter.unit_of_work).to eq(:datagram)
      expect(adapter.thread_count).to eq(2)
      expect(adapter.admission_cap).to be_nil
      expect(adapter.drain_deadline).to eq(Takagi::Server::Udp::DRAIN_DEADLINE)
      expect(adapter.drain_deadline).to be < Takagi::Server::Cluster::WORKER_TERM_TIMEOUT
    ensure
      server&.shutdown!
    end

    it 'declares no second bind: the adapter hands over the socket the constructor bound, with no SO_REUSEPORT' do
      server = Takagi::Server::Udp.new(port: 0)
      socket = server.instance_variable_get(:@socket)

      expect(server.send(:build_cluster_adapter).fds).to eq([socket])
      expect(socket.getsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEPORT).bool).to be(false)
    ensure
      server&.shutdown!
    end

    it 'arms the worker with the driver stop state, so no child has to ask the kernel for its parent' do
      server = Takagi::Server::Udp.new(port: 0, worker_processes: 1)
      worker = server.send(:build_worker)

      expect(worker.send(:stop_requested?)).to be(false)
      server.cluster.stop!
      expect(worker.send(:stop_requested?)).to be(true)
    ensure
      server&.shutdown!
    end
  end

  describe 'count 1 serves in-process' do
    it 'answers a real exchange in this process, forks nothing and leaves no child to reap' do
      logger = UdpWorkersRecordingLogger.new
      server = Takagi::Server::Udp.new(port: 0, worker_processes: 1, worker_threads: 2, logger: logger)
      port = bound_port(server)
      expect(server.cluster.forking?).to be(false)
      runner = Thread.new { server.run! }

      expect(exchange(port)).to include('Pong')

      # No child of this process exists at all: nothing was forked for this server.
      expect(server.worker_pids).to be_nil
      expect { Process.waitpid(-1, Process::WNOHANG) }.to raise_error(Errno::ECHILD)

      # The serving loop ran HERE: its log line carries this process's pid.
      line = await_log_line(logger) { |entry| entry.include?('Worker PID:') }
      expect(line).to include("[Worker PID: #{Process.pid}]")
    ensure
      server&.shutdown!
      runner&.join(5)
    end

    it 'releases the port on shutdown without leaving a child behind' do
      server = Takagi::Server::Udp.new(port: 0, worker_processes: 1, worker_threads: 1)
      port = bound_port(server)
      runner = Thread.new { server.run! }
      expect(exchange(port)).to include('Pong')

      server.shutdown!
      runner.join(5)

      expect { UDPSocket.new.tap { |socket| socket.bind('127.0.0.1', port) }.close }.not_to raise_error
      expect { Process.waitpid(-1, Process::WNOHANG) }.to raise_error(Errno::ECHILD)
    ensure
      server&.shutdown!
      runner&.join(5)
    end
  end

  describe 'workers served by the cluster' do
    it 'titles every child takagi-worker-<index> with no transport in the title' do
      server = Takagi::Server::Udp.new(port: 0, worker_processes: 3, worker_threads: 1)
      expect(server.cluster.forking?).to be(true)
      runner = Thread.new { server.run! }

      pids = await_worker_pids(server, 3)
      expect(pids).not_to be_nil, "no three worker pids; server.worker_pids=#{server.worker_pids.inspect}"
      expect(pids.each_index.map { |index| await_worker_title(pids[index], "takagi-worker-#{index}") })
        .to eq(%w[takagi-worker-0 takagi-worker-1 takagi-worker-2])
      expect(pids.map { |pid| cmdline_of(pid) }).to all(satisfy { |title| !title.match?(/tcp|udp/i) })

      # The children serve the socket the master bound, not one of their own.
      expect(exchange(bound_port(server))).to include('Pong')

      # Teardown through the real surface, and no child is left to serve this port.
      server.shutdown!
      runner.join(5)
      expect(pids.map { |pid| gone?(pid) }).to all(be(true))
    ensure
      server&.shutdown!
      runner&.join(5)
    end

    it 'answers a datagram from a forked child on the inherited socket' do
      server = Takagi::Server::Udp.new(port: 0, worker_processes: 2, worker_threads: 1)
      port = bound_port(server)
      runner = Thread.new { server.run! }

      pids = await_worker_pids(server, 2)
      expect(pids).not_to be_nil
      expect(exchange(port)).to include('Pong')
    ensure
      server&.shutdown!
      runner&.join(5)
    end

    it 'reaps a SIGKILLed child, respawns it under its own index, and logs exactly one WARN naming pid, index, status and replacement' do
      logger = UdpWorkersRecordingLogger.new
      server = Takagi::Server::Udp.new(port: 0, worker_processes: 2, worker_threads: 1, logger: logger)
      port = bound_port(server)
      runner = Thread.new { server.run! }

      pids = await_worker_pids(server, 2)
      expect(pids).not_to be_nil
      expect(exchange(port)).to include('Pong')

      victim = pids.first
      index = pids.index(victim)
      Process.kill('KILL', victim)

      restored = await_replacement(server, pids)
      expect(restored).not_to be_nil, "the killed child was not replaced; worker_pids=#{server.worker_pids.inspect}"
      replacement = (restored - pids).first
      expect(replacement).not_to be_nil
      expect(restored).to include(*(pids - [victim]))
      # The replacement takes over the dead worker's index, so its title stays truthful.
      expect(await_worker_title(replacement, "takagi-worker-#{index}")).to eq("takagi-worker-#{index}")

      death = await_log_line(logger) { |entry| entry.include?("worker #{victim}") }
      expect(death).not_to be_nil, "no death line; log=#{logger.snapshot.inspect}"
      expect(death).to include("worker #{victim} (index #{index})")
      expect(death).to include('respawned as')
      expect(death).to include(replacement.to_s)
      expect(death).to include('SIGKILL')
      expect(logger.snapshot.count { |entry| entry.include?("worker #{victim}") }).to eq(1)

      # The restored pool still serves the port.
      expect(exchange(port)).to include('Pong')

      server.shutdown!
      runner.join(5)
      expect(restored.map { |pid| gone?(pid) }).to all(be(true))
    ensure
      server&.shutdown!
      runner&.join(5)
    end
  end

  describe 'the parent-death guard the worker no longer computes for itself' do
    # The SHAPE this row forbids: a future change cannot quietly reintroduce the arm inside the
    # worker. The DISCRIMINATOR is the forced-interleaving example below, which makes the race
    # happen on demand and fails when the arm moves back to a post-fork read.
    it 'leaves every parent-pid read out of the worker: the driver arms it from the pre-fork capture' do
      source = File.read(File.expand_path('../../lib/takagi/server/udp_worker.rb', __dir__))

      expect(source).not_to include('Process.ppid')
    end
  end

  # Row 7: the datagram distribution across the children, pinned by a forced choreography instead
  # of a burst. With several children blocked in their own read on the SAME inherited socket the
  # kernel decides which one wakes, so a burst ratio is not an observable of "every child serves".
  # Here exactly ONE child is ever runnable - its siblings are STOPped and their STOP is AWAITED
  # before a datagram is sent, so the observation is armed before the trigger - and the child that
  # handled the datagram NAMES ITSELF through a stack this spec injects, so the attribution is a
  # value (a pid), never a reading of log prose.
  class UdpServedPidRecorder
    def initialize(writer)
      @writer = writer
      @writer.sync = true
      @delegate = Takagi::MiddlewareStack.instance
    end

    def call(request)
      @writer.puts(Process.pid)
      @delegate.call(request)
    end
  end

  describe 'datagram distribution across the children (row 7)' do
    it 'answers a datagram on the one child left running, named by the child that handled it' do
      reader, writer = IO.pipe
      server = Takagi::Server::Udp.new(port: 0, worker_processes: 3, worker_threads: 1,
                                       middleware_stack: UdpServedPidRecorder.new(writer))
      runner = Thread.new { server.run! }
      port = bound_port(server)
      stopped = []
      served_by = []

      pids = await_worker_pids(server, 3)
      expect(pids).not_to be_nil, "no three worker pids; server.worker_pids=#{server.worker_pids.inspect}"

      pids.each do |pid|
        # This child takes its turn and every sibling is stopped, with the stop AWAITED before
        # anything is attributed: a STOPped child cannot read the shared socket, so the child that
        # answers is the one this example left runnable.
        resume_quietly(pid)
        expect(await(seconds: 5) { pid_state(pid) == 'T' ? nil : true }).to be(true),
                                                                          "child #{pid} never resumed"
        others = pids - [pid]
        others.each { |other| resume_quietly(other, 'STOP') }
        stopped = others
        expect(await(seconds: 5) { others.all? { |other| pid_state(other) == 'T' } ? true : nil }).to be(true),
                                                                                                "siblings of #{pid} never stopped"

        expect(exchange(port)).to include('Pong')
        served = read_bounded(reader, seconds: 5)
        served_by << served&.to_i
        expect(served&.to_i).to eq(pid), "the datagram was handled by #{served.inspect}, not by #{pid}"
      end

      # Every child took its turn, in the order the choreography forced: that is the distribution
      # itself, never a ratio read off a burst.
      expect(served_by).to eq(pids)
      expect(server.worker_pids).to eq(pids)
    ensure
      stopped.each { |pid| resume_quietly(pid) }
      pids&.each { |pid| resume_quietly(pid) }
      server&.shutdown!
      runner&.join(5)
      reader&.close
      writer&.close
    end
  end

  # Row 7: the orphan path of row 2's contract, FORCED instead of raced, and repeated. The hook
  # that SIGSTOPs every just-forked child is installed on the cluster BEFORE `run!` reaches the
  # fork, so the observation is ARMED BEFORE THE TRIGGER; each counted attempt is PROVEN from /proc
  # before the master is killed - every child must be state 'T', still parented to the master, and
  # still carrying the MASTER's cmdline, which proves `Process.setproctitle` (the child's first
  # statement, before the arming one) never ran. An attempt whose STOP lost that race is DISCARDED,
  # never counted. On the shipped bytes the child compares the parent link against the master pid
  # the cluster captured BEFORE the fork, so the master's death is seen and the child leaves; with
  # the arm moved back to a post-fork read (the pre-row-2 bytes' shape) every child ADOPTS the reaper
  # and serves the inherited socket forever - measured: 20 survivors of 20 children.
  describe 'the orphan path, forced by interleaving (row 7)' do
    def udp_orphan_master_title = 'takagi-worker-udp-spec-master'

    # "repetitions (>= 10) for anything timing-shaped": a SIGSTOP that must beat a child's first
    # statement is a race, so the choreography is repeated and every repetition is proven pre-arm.
    def interleaving_repetitions = 10

    def interleaving_attempt_cap = 200

    # ONE forced interleaving. Returns :discarded when the STOP lost the race, or
    # [survivors, port] for a counted attempt: the children that outlived the master by the stated
    # deadline, and the port they inherited from it.
    def forced_orphan_attempt(master_title, workers: 2, proof_seconds: 2.0, survivor_seconds: 2.0)
      reader, writer = IO.pipe
      master_pid = fork do
        reader.close
        Process.setproctitle(master_title)
        server = Takagi::Server::Udp.new(port: 0, worker_processes: workers, worker_threads: 1)
        cluster = server.cluster
        original = cluster.method(:fork_worker)
        # The SIGSTOP is issued by the MASTER the instant the fork returns, so the child is frozen
        # in the parent branch before it can run its first statement. The stopper is a closure,
        # because inside the singleton method `self` is the cluster, not this example.
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

      port = await(seconds: 10) do
        next nil unless reader.wait_readable(0.2)

        line = reader.gets
        line && line[/\APORT (\d+)/, 1]&.to_i
      end
      raise 'the forked master never reported its port' if port.nil?

      proof = await(seconds: proof_seconds) do
        kids = children_of(master_pid)
        next nil unless kids.size == workers

        fields = kids.map { |pid| [pid, pid_state(pid), ppid_of(pid), cmdline_of(pid)] }
        # A child that already carries its own title has armed itself, so this STOP lost the race.
        next :lost if fields.any? { |_pid, _state, _ppid, title| title != master_title }

        fields.all? { |_pid, state, ppid, _title| state == 'T' && ppid == master_pid } ? kids : nil
      end

      if proof.nil? || proof == :lost
        discard_attempt(master_pid)
        return :discarded
      end

      # THE TRIGGER: the master dies while its children are frozen BEFORE their first statement,
      # so whatever they do next is decided by the value the cluster armed them with.
      Process.kill('KILL', master_pid)
      Process.waitpid(master_pid)
      proof.each { |pid| resume_quietly(pid) }

      survivors = await(seconds: survivor_seconds) do
        alive = proof.reject { |pid| gone?(pid) }
        alive.empty? ? [] : nil
      end || proof.dup
      survivors.each { |pid| kill_quietly(pid) }
      await(seconds: 2) { proof.all? { |pid| gone?(pid) } ? true : nil }
      [survivors, port]
    ensure
      reader&.close
    end

    # A discarded attempt still forked children, and they must end BEFORE the master, or the
    # master's death reparents them and they keep serving on the inherited socket.
    def discard_attempt(master_pid)
      children_of(master_pid).each do |pid|
        resume_quietly(pid)
        kill_quietly(pid)
      end
      kill_quietly(master_pid)
      Process.waitpid(master_pid)
    rescue Errno::ECHILD, Errno::ESRCH
      nil
    end

    it 'leaves no child serving the inherited socket when the master dies before a child ever runs' do
      master_title = udp_orphan_master_title
      counted = 0
      discarded = 0
      attempts = 0
      survivors = []

      while counted < interleaving_repetitions && attempts < interleaving_attempt_cap
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
      expect(counted).to eq(interleaving_repetitions),
                         "only #{counted} of #{interleaving_repetitions} forced interleavings were " \
                         "PROVEN in #{attempts} attempts (#{discarded} discarded)"
      expect(survivors).to be_empty,
                            "#{survivors.size} child(ren) outlived the master that forked them: " \
                            "#{survivors.inspect}"
    end
  end
end
