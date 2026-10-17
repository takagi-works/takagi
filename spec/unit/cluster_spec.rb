# frozen_string_literal: true

require 'timeout'
require 'spec_helper'

# Direct coverage of the ONE supervisor: the transport-free worker identity, the count-1
# in-process shape, and the adapter contract the cluster is served through. The
# transport-level lifecycle (fork/reap/respawn/shutdown ordering) stays in
# spec/unit/tcp_workers_spec.rb, which drives a real master.
RSpec.describe Takagi::Server::Cluster do
  def bound_port(server)
    server.instance_variable_get(:@server).addr[1]
  end

  # Bounded wait on a real observable: returns the instant the condition holds, and its
  # failure is the assertion's rather than a timeout's.
  def await(seconds)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    loop do
      value = yield
      return value if value
      return nil if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.01
    end
  end

  def title_of(pid)
    File.read("/proc/#{pid}/cmdline").split("\0").first
  rescue Errno::ENOENT, Errno::ESRCH
    nil
  end

  def read_tcp_message(socket)
    loop do
      return nil unless socket.wait_readable(5)

      raw = Takagi::Network::Framing::Tcp.read_from_socket(socket)
      return nil unless raw
      return raw unless Takagi::CoAP::Registries::Signaling.signaling?(raw.getbyte(1))
    end
  end

  def ping_frame
    Takagi::Message::Outbound.new(
      code: 1, payload: nil, token: '12345678', options: { 11 => ['ping'] }, transport: :tcp
    ).to_bytes(transport: :tcp)
  end

  def ping_over_tcp(port)
    client = TCPSocket.new('127.0.0.1', port)
    client.write(ping_frame)
    raw = read_tcp_message(client)
    client.close
    raw && Takagi::Message::Inbound.new(raw, transport: :tcp)
  end

  # Only the master writes here: a forked child's copies of this object are private to it,
  # so this records exactly what the supervising process itself reported.
  class MasterLog
    def initialize
      @mutex = Mutex.new
      @lines = []
    end

    def info(_message); end

    def debug(_message); end

    def warn(message)
      @mutex.synchronize { @lines << "WARN #{message}" }
    end

    def error(message)
      @mutex.synchronize { @lines << "ERROR #{message}" }
    end

    def lines
      @mutex.synchronize { @lines.dup }
    end
  end

  def kill_quietly(pid)
    Process.kill('KILL', pid)
  rescue Errno::ESRCH
    nil
  end

  # Starts a server through the public constructor on a kernel-chosen port and runs it on a
  # thread, so the spec observes the server's OWN state (worker_pids) as the master holds it.
  def serve_on_thread(worker_processes, log)
    server = Takagi::Server::Tcp.new(port: 0, worker_processes: worker_processes, logger: log)
    runner = Thread.new { server.run! }
    pids = await(10) do
      list = server.worker_pids
      list && list.size == worker_processes ? list.dup : nil
    end
    [server, runner, pids]
  end

  describe 'the transport-free worker identity' do
    it 'titles every fork takagi-worker-<index>, with no transport in the title' do
      log = MasterLog.new
      server = nil
      runner = nil
      pids = []
      begin
        server, runner, pids = serve_on_thread(3, log)
        expect(pids&.size).to eq(3)

        titles = pids.each_with_index.map do |pid, index|
          [index, await(5) { title_of(pid) == "takagi-worker-#{index}" ? title_of(pid) : nil }]
        end
        expect(titles).to eq([[0, 'takagi-worker-0'], [1, 'takagi-worker-1'], [2, 'takagi-worker-2']])
      ensure
        pids.compact.each { |pid| kill_quietly(pid) }
        server&.shutdown!
        runner&.join(5)
      end
    end
  end

  describe 'the adapter contract' do
    it 'is declared on Cluster::Adapter, naming every method a transport must supply' do
      declared = %i[fds serve_loop stop_requested? stop! prepare_process unit_of_work thread_count
                    admission_cap drain_deadline]

      expect(declared - Takagi::Server::Cluster::Adapter.instance_methods).to be_empty
    end

    it 'declares the TCP adapter facts off the server that owns them' do
      server = Takagi::Server::Tcp.new(port: 0, worker_processes: 3, worker_threads: 2, max_connections: 5)
      adapter = server.cluster.instance_variable_get(:@adapters).first

      expect(adapter.unit_of_work).to eq(:connection)
      expect(adapter.thread_count).to eq(2)
      expect(adapter.admission_cap).to eq(5)
      expect(adapter.fds).to eq([server.instance_variable_get(:@server)])
      # The child's drain deadline must stay strictly inside the master's batch TERM->KILL
      # deadline, so a child stops before its master escalates.
      expect(adapter.drain_deadline).to be < Takagi::Server::Cluster::WORKER_TERM_TIMEOUT
    ensure
      server&.shutdown!
    end
  end

  describe 'a count of 1' do
    it 'forks nothing and serves a real exchange itself' do
      server = Takagi::Server::Tcp.new(port: 0, worker_processes: 1)
      runner = Thread.new { server.run! }
      port = bound_port(server)

      expect(ping_over_tcp(port)&.payload).to include('Pong')
      expect(server.cluster.forking?).to be(false)
      expect(server.worker_pids).to be_nil
      # No child of this process exists at all, so there is nothing for waitpid to collect.
      expect { Process.waitpid(-1, Process::WNOHANG) }.to raise_error(Errno::ECHILD)
    ensure
      server&.shutdown!
      runner&.join(5)
    end

    it 'leaves no child behind after a stop, reported by Process.waitpid' do
      log = MasterLog.new
      server = nil
      runner = nil
      pids = []
      begin
        server, runner, pids = serve_on_thread(2, log)
        expect(pids&.size).to eq(2)

        server.shutdown!

        # waitpid is the authority: a zombie still answers kill(0), so kill(0) alone could
        # pass for the wrong reason. The master reaped these, so waitpid raises ECHILD.
        pids.each do |pid|
          expect { Process.waitpid(pid) }.to raise_error(Errno::ECHILD)
          expect { Process.kill(0, pid) }.to raise_error(Errno::ESRCH)
        end
      ensure
        pids.compact.each { |pid| kill_quietly(pid) }
        server&.shutdown!
        runner&.join(5)
      end
    end
  end
end
