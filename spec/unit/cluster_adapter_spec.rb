# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'
require 'spec_helper'

# Plan row 5 (unified-cluster): the adapter contract, pinned by a STUB transport that is the
# only transport this file knows. Nothing here builds a TCP or a UDP server: the transport is a
# spec-local class (`ClusterAdapterStub`) that declares the contract's four facts and implements
# its five calls, and the cluster is then observed DRIVING it alone - forking N titled children,
# replacing a killed one with exactly one WARN, and draining an in-flight unit on TERM. The
# cluster's own copy of the contract is what its implementers read (`Cluster::Adapter`), and the
# proof that the cluster never names a transport is that this transport - which matches no
# transport name - is served in full.
#
# Every wait in this file is bounded and waits on a real observable: a worker pid read from the
# process table, a receipt file the serving process itself wrote, or the master's own log file.
# Above a count of 1 the cluster is run by a MASTER THIS FILE FORKS, so it receives a real TERM
# and this process is never signalled; the master's children are its own, so their titles,
# deaths and respawns are read from /proc and from the master's log, never from this process's
# memory.
RSpec.describe 'Takagi transport adapter contract (plan row 5)' do
  # A STUB TRANSPORT: the only transport this file knows. It implements the contract and
  # declares facts no shipped transport declares today (`unit_of_work == :stream`), so a
  # cluster that branched on a transport's identity would fail on it. Its serve loop does three
  # real things: it announces the process that serves (a receipt only that process can write),
  # it takes ONE unit of work off the inherited socket, and it finishes a unit that was in
  # flight when the stop arrived, inside the drain deadline it DECLARES to the cluster.
  class ClusterAdapterStub
    include Takagi::Server::Cluster::Adapter

    # The drain window the stub declares: strictly below the master's batch TERM->KILL deadline
    # (`Cluster::WORKER_TERM_TIMEOUT`), which is the contract's order rule.
    DRAIN_DEADLINE = 0.5
    # The stub's read timeout on the socket: a bounded read, never a pause.
    POLL = 0.05

    attr_reader :fds, :unit_of_work, :thread_count, :admission_cap, :drain_deadline
    attr_accessor :stop_check

    def initialize(fds:, work_dir:, unit_of_work: :stream, thread_count: 2,
                   admission_cap: nil, drain_deadline: DRAIN_DEADLINE)
      @fds = fds
      @work_dir = work_dir
      @unit_of_work = unit_of_work
      @thread_count = thread_count
      @admission_cap = admission_cap
      @drain_deadline = drain_deadline
      @stop_check = -> { false }
      @processed = 0
    end

    # The serve loop, run once per serving process: a forked child above a count of 1, the
    # master itself at 1. The receipt is written by THIS process, so it is the evidence that
    # the cluster ran the loop here rather than somewhere else.
    def serve_loop
      receipt("serving-#{Process.pid}", "#{@unit_of_work} threads=#{@thread_count}")
      until stop_check.call
        next unless read_unit

        finish_unit
      end
      drain
    end

    def stop_requested? = stop_check.call

    # Idempotent and trap-safe, as the contract demands: the stub holds no state to unwind.
    def stop!; end

    # Per-process state belongs to the serving process: reset right after the fork.
    def prepare_process
      @processed = 0
    end

    private

    def read_unit
      return false unless @fds.first.wait_readable(POLL)

      @data, _address = @fds.first.recvfrom_nonblock(65_535)
      true
    rescue IO::WaitReadable, Errno::EINTR, IOError
      false
    end

    # ONE unit of work, in the drain contract's shape: the unit is announced when it starts (so
    # an example can put a stop in flight while this unit is unfinished), it finishes only when
    # its work is released - bounded by THIS transport's declared drain deadline - and the
    # receipt records whether the stop had been requested when the work finished. That last fact
    # is the difference between draining and aborting.
    def finish_unit
      @processed += 1
      receipt("unit-started-#{Process.pid}", @data.inspect)
      released = await_file('release', @drain_deadline)
      stopped = await_true(@drain_deadline) { stop_check.call }
      receipt("unit-done-#{Process.pid}", "released=#{released} stopping=#{stopped}")
    end

    # Leaving is a drain, not an abort: the loop left only after the in-flight unit finished,
    # and this receipt records how many units the process completed before it left.
    def drain
      receipt("drained-#{Process.pid}", "units=#{@processed}")
    end

    def receipt(name, body)
      File.write(File.join(@work_dir, name), body)
    end

    def await_file(name, seconds)
      !!await_true(seconds) { File.exist?(File.join(@work_dir, name)) }
    end

    def await_true(seconds)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      loop do
        return true if yield
        return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        IO.select(nil, nil, nil, POLL)
      end
    end
  end

  # The master's log, kept as a FILE: the assertions read what the SUPERVISING process wrote,
  # across the fork boundary, instead of this process's copy of any object. The WARN COUNT is
  # the row's observable, never the wording of a message.
  class ClusterAdapterStubLog
    def initialize(path)
      @path = path
      @io = File.open(path, 'a')
      @io.sync = true
    end

    def debug(_message); end
    def info(_message); end
    def warn(message) = append('WARN', message)
    def error(message) = append('ERROR', message)
    def lines = File.readlines(@path)
    def close = @io.close

    private

    def append(level, message)
      @io.write("#{level} #{message}\n")
      @io.flush
    end
  end

  # What one example holds: the cluster (the object the master runs), its ONE adapter, the log,
  # the socket the adapter declared, the scratch directory the receipts land in, the forked
  # master's pid, and the port the socket earned.
  ClusterAdapterStubService = Struct.new(:cluster, :adapter, :log, :socket, :work_dir, :master, :port) do
    # Every process that ever served here, read from the receipts it wrote. The spec's own pid is
    # never a worker (the stub only ever runs in a forked master or its child), so it is excluded.
    def known_pids
      Dir[File.join(work_dir, '*-*')].filter_map { |path| File.basename(path)[/-(\d+)\z/, 1]&.to_i }
                                     .uniq.reject { |pid| pid == Process.pid }
    end
  end

  def observable_deadline = 10.0

  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  # Bounded wait on an observable: returns the instant the block yields a value, and its failure
  # is the assertion's - never a timeout's.
  def await(seconds)
    deadline = now + seconds
    loop do
      value = yield
      return value if value
      return nil if now >= deadline

      sleep 0.01
    end
  end

  def pid_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  def kill_quietly(pid, signal = 'TERM')
    return if pid.nil?

    Process.kill(signal, pid)
  rescue Errno::ESRCH
    nil
  end

  def wait_reaped(pid, seconds)
    return true if pid.nil?

    await(seconds) { Process.waitpid(pid, Process::WNOHANG) ? true : nil }
  rescue Errno::ECHILD
    true
  end

  # The title the kernel holds for a process - the observable the row's titles live in.
  def pid_title(pid)
    File.read("/proc/#{pid}/cmdline").split("\0").first
  rescue Errno::ENOENT, Errno::ESRCH
    nil
  end

  # The children a process holds, read from the kernel rather than from the master's state.
  def children_of(pid)
    File.read("/proc/#{pid}/task/#{pid}/children").split.map(&:to_i)
  rescue Errno::ENOENT, Errno::ESRCH, Errno::EACCES
    []
  end

  # True when the process holds the VERY socket the adapter declared, so the fd crossed the fork.
  def holds_fd?(pid, socket)
    link = "socket:[#{socket.stat.ino}]"
    Dir["/proc/#{pid}/fd/*"].any? { |fd| File.readlink(fd) == link }
  rescue Errno::ENOENT, Errno::ESRCH, Errno::EACCES
    false
  end

  def receipt_path(service, name) = File.join(service.work_dir, name)

  def receipt_pids(service, prefix)
    Dir[File.join(service.work_dir, "#{prefix}-*")].filter_map { |p| File.basename(p)[/-(\d+)\z/, 1]&.to_i }
  end

  def receipt_body(service, name)
    File.read(receipt_path(service, name))
  rescue Errno::ENOENT
    nil
  end

  # The service the contract allows: ONE adapter, the stub, and no transport at all.
  def build_stub_service(count)
    work_dir = Dir.mktmpdir('cluster-adapter-stub')
    socket = UDPSocket.new
    socket.bind('127.0.0.1', 0)
    log = ClusterAdapterStubLog.new(File.join(work_dir, 'master.log'))
    service = ClusterAdapterStubService.new(nil, nil, log, socket, work_dir, nil, socket.addr[1])
    service.adapter = ClusterAdapterStub.new(fds: [socket], work_dir: work_dir)
    service.cluster = Takagi::Server::Cluster.new(count: count, adapters: [service.adapter],
                                                  logger: service.log)
    service.adapter.stop_check = -> { service.cluster.stopping? }
    service
  end

  def close_stub_service(service)
    service.log&.close
    service.socket&.close
    FileUtils.remove_entry(service.work_dir) if service.work_dir && File.directory?(service.work_dir)
  end

  # Runs a service through a MASTER OF ITS OWN, so the cluster receives a real TERM and this
  # process is never signalled.
  def with_stub_service(count)
    service = build_stub_service(count)
    service.master = fork do
      Process.setproctitle('cluster-adapter-stub-master')
      service.cluster.run!
      exit!(0)
    end
    yield service
  ensure
    teardown_stub_service(service) if service
  end

  # The cluster's own stop path first (TERM, and KILL only past its batch deadline), then a
  # sweep of everything that ever served here, then the resources. The survivors assertion is
  # the row's teardown requirement expressed as a value: no pid that served outlives the example.
  def teardown_stub_service(service)
    master = service.master
    kill_quietly(master, 'TERM') if master
    wait_reaped(master, observable_deadline) if master
    if master && pid_alive?(master)
      kill_quietly(master, 'KILL')
      wait_reaped(master, 2.0)
    end
    service.known_pids.each { |pid| kill_quietly(pid, 'KILL') }
    cleared = await(2.0) { service.known_pids.none? { |pid| pid_alive?(pid) } ? true : nil }
    close_stub_service(service)
    expect(cleared).to be(true),
                       "pids that served outlived the example: #{service.known_pids.select { |pid| pid_alive?(pid) }}"
  end

  describe 'the contract a transport implements' do
    it 'is exactly the surface the stub supplies, and the stub is the only transport handed over' do
      declared_calls = %i[fds serve_loop stop_requested? stop! prepare_process]
      declared_facts = %i[unit_of_work thread_count admission_cap drain_deadline]

      # The stub's whole transport surface IS the contract: the cluster can reach nothing else.
      expect(declared_calls - ClusterAdapterStub.instance_methods).to be_empty
      expect(declared_facts - ClusterAdapterStub.instance_methods).to be_empty

      service = build_stub_service(2)
      begin
        stub = service.adapter
        expect(stub.fds).to eq([service.socket])
        expect(stub.unit_of_work).to eq(:stream)
        expect(stub.thread_count).to eq(2)
        expect(stub.admission_cap).to be_nil
        expect(stub.drain_deadline).to eq(ClusterAdapterStub::DRAIN_DEADLINE)
        expect(stub.drain_deadline).to be < Takagi::Server::Cluster::WORKER_TERM_TIMEOUT
        # The ONLY transport this file registers: one adapter, and it is the stub.
        expect(service.cluster.instance_variable_get(:@adapters).map(&:class)).to eq([ClusterAdapterStub])
      ensure
        close_stub_service(service)
      end
    end
  end

  describe 'the cluster driving the stub transport alone' do
    it 'forks N children titled takagi-worker-<index>, each serving the stub loop in its own process' do
      with_stub_service(3) do |service|
        serving = await(observable_deadline) do
          pids = receipt_pids(service, 'serving')
          pids.size == 3 ? pids.sort : nil
        end
        expect(serving).not_to be_nil, 'the stub never announced three serving processes'
        expect(serving).to eq(children_of(service.master).sort)

        titles = await(observable_deadline) do
          seen = children_of(service.master).map { |pid| pid_title(pid) }.compact.sort
          seen.size == 3 ? seen : nil
        end
        expect(titles).to eq(%w[takagi-worker-0 takagi-worker-1 takagi-worker-2])
        # The title carries no transport, and every child holds the ONE socket the stub declared.
        expect(serving).to all(satisfy { |pid| holds_fd?(pid, service.socket) })
        expect(service.log.lines.grep(/\AWARN/)).to be_empty
      end
    end

    it 'replaces a killed child one-for-one and logs exactly one WARN naming both pids' do
      with_stub_service(2) do |service|
        serving = await(observable_deadline) do
          pids = receipt_pids(service, 'serving')
          pids.size == 2 ? pids.sort : nil
        end
        expect(serving).not_to be_nil, 'the stub never announced two serving processes'
        victim = serving.find { |pid| pid_title(pid) == 'takagi-worker-1' }
        expect(victim).not_to be_nil, "no worker 1 among #{serving.inspect}"
        survivor = (serving - [victim]).first

        kill_quietly(victim, 'KILL')

        warn_line = await(observable_deadline) do
          warnings = service.log.lines.grep(/\AWARN/)
          warnings.size == 1 ? warnings.first : nil
        end
        expect(warn_line).not_to be_nil, "expected exactly one WARN, saw #{service.log.lines.inspect}"
        dead_pid, index, replacement = warn_line.match(/worker (\d+) \(index (\d+)\).*respawned as (\d+)/).captures
        expect(dead_pid.to_i).to eq(victim)
        expect(index).to eq('1')
        expect(replacement.to_i).not_to eq(victim)

        # The replacement carries the dead worker's index and really serves: its own receipt, and
        # the socket fd it inherited from the master.
        title = await(observable_deadline) do
          seen = pid_title(replacement.to_i)
          seen == 'takagi-worker-1' ? seen : nil
        end
        expect(title).to eq('takagi-worker-1')
        expect(await(observable_deadline) { File.exist?(receipt_path(service, "serving-#{replacement}")) ? true : nil })
          .to be(true), "the replacement #{replacement} never served"
        expect(holds_fd?(replacement.to_i, service.socket)).to be(true)
        # One-for-one: the count is restored and the dead pid is gone, with still exactly one WARN.
        restored = await(observable_deadline) do
          children_of(service.master).sort == [survivor, replacement.to_i].sort ? true : nil
        end
        expect(restored).to be(true), "children were #{children_of(service.master).inspect}"
        expect(await(observable_deadline) { pid_alive?(victim) ? nil : true }).to be(true)
        expect(service.log.lines.grep(/\AWARN/).size).to eq(1)
      end
    end

    it 'drains an in-flight unit on TERM inside the deadline it declared, then leaves' do
      with_stub_service(2) do |service|
        await(observable_deadline) do
          pids = receipt_pids(service, 'serving')
          pids.size == 2 ? true : nil
        end

        service.socket.send('in-flight-unit', 0, '127.0.0.1', service.port)
        holder = await(observable_deadline) { receipt_pids(service, 'unit-started').first }
        expect(holder).not_to be_nil, 'no worker ever started the unit'
        expect(pid_title(holder)).to match(/\Atakagi-worker-\d+\z/)

        stopped_at = now
        Process.kill('TERM', service.master) # the master's stop path: TERM each child...
        File.write(File.join(service.work_dir, 'release'), 'released') # ...while this unit is unfinished
        expect(wait_reaped(service.master, observable_deadline)).to be(true), 'the master never exited'
        elapsed = now - stopped_at

        done = await(observable_deadline) { receipt_body(service, "unit-done-#{holder}") }
        expect(done).to include('released=true')
        # The stop had already been requested when the unit finished: the unit DRAINED instead of
        # being aborted, which is the whole point of the declared drain deadline.
        expect(done).to include('stopping=true')
        # Leaving is a drain too: the worker recorded the units it completed before it left.
        expect(receipt_body(service, "drained-#{holder}")).to include('units=1')
        expect(await(observable_deadline) { pid_alive?(holder) ? nil : true }).to be(true)
        expect(elapsed).to be < Takagi::Server::Cluster::WORKER_TERM_TIMEOUT + 1.0,
                             "the stop took #{elapsed.round(3)} s, past the master's batch deadline"
      end
    end
  end

  describe 'a count of 1' do
    it 'serves the stub in the master process itself and forks no child at all' do
      with_stub_service(1) do |service|
        expect(service.cluster.forking?).to be(false)

        served = await(observable_deadline) do
          File.exist?(receipt_path(service, "serving-#{service.master}")) ? true : nil
        end
        expect(served).to be(true), 'the master did not serve through the stub loop itself'
        expect(children_of(service.master)).to be_empty

        # ONE unit of work, served by the master process itself - there is no child to serve it.
        File.write(File.join(service.work_dir, 'release'), 'released')
        service.socket.send('solo-unit', 0, '127.0.0.1', service.port)
        holder = await(observable_deadline) { receipt_pids(service, 'unit-started').first }
        expect(holder).to eq(service.master)
        expect(await(observable_deadline) { receipt_body(service, "unit-done-#{service.master}") ? true : nil })
          .to be(true), 'the in-process unit never finished'
        expect(children_of(service.master)).to be_empty
      end
    end
  end
end
