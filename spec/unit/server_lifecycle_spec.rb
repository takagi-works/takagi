# frozen_string_literal: true

require 'stringio'

RSpec.describe Takagi::Base::ServerLifecycle do
  subject(:lifecycle) { Class.new { include Takagi::Base::ServerLifecycle }.new }

  let(:config) { Takagi.config }
  let(:log_io) { StringIO.new }
  let(:servers) { [] }

  before do
    allow(Takagi).to receive(:logger)
      .and_return(Takagi::Logger.new(log_output: log_io, level: ::Logger::WARN))
    allow(config).to receive_messages(
      threads: 1,
      max_connections: nil,
      protocols: [:udp]
    )
  end

  after do
    servers.each do |server|
      server.instance_variable_get(:@server)&.close
      server.instance_variable_get(:@socket)&.close
    end
    # Row 23: the presence carrier is process-wide state on the singleton, so an example that
    # drives it for real hands it back here instead of leaving it for the next spec file.
    Takagi.config.reset_written_keys!
  end

  # Presence is an explicit INPUT of each example rather than state read off the shared
  # `Takagi.config` singleton (rows 23/24): the examples that need a key to count as WRITTEN say
  # which keys are written, and the ones that do not stay silent by construction. So no example
  # depends on spec order, and none needs the blanket `written?: false` stub that used to sit in
  # the `before` block.
  def written_keys_stub(*keys)
    allow(config).to receive(:written?) { |key| keys.include?(key.to_sym) }
  end

  def configured_processes(protocol, protocol_settings:, global_processes:, written: [])
    allow(config).to receive(:protocol_settings).and_return(protocol_settings)
    allow(config).to receive(:processes).and_return(global_processes)
    written_keys_stub(*written)

    server = lifecycle.send(:build_servers, [protocol], 0).first
    servers << server
    server
  end

  def warnings
    log_io.string.lines.grep(/WARN/)
  end

  # Row 3 of .omo/plans/unified-cluster.md: a service has ONE worker count. The top-level
  # `processes` is the count the cluster forks and it reaches EVERY transport the service
  # exposes; a per-protocol `processes` survives only as a compatibility alias, accepted
  # solely when it restates that one count.
  describe 'the one worker count of a service (row 3)' do
    def built_for_processes(protocols, protocol_settings:, processes: 1, written: [])
      allow(config).to receive_messages(protocol_settings: protocol_settings, threads: 1, processes: processes)
      written_keys_stub(*written)
      lifecycle.send(:build_servers, protocols, 0).tap { |built| servers.concat(built) }
    end

    it 'reaches BOTH transports from the written global count (PROOF)' do
      udp_server, tcp_server = built_for_processes(%i[udp tcp], protocol_settings: {}, processes: 2,
                                                                    written: [:processes])

      expect(udp_server.instance_variable_get(:@worker_processes)).to eq(2)
      expect(tcp_server.instance_variable_get(:@worker_processes)).to eq(2)
      expect(warnings).to be_empty
    end

    it 'accepts a lone per-protocol count as the service count and applies it to both transports (GUARD A)' do
      udp_server, tcp_server = built_for_processes(%i[udp tcp], protocol_settings: { tcp: { processes: 2 } })

      expect(tcp_server.instance_variable_get(:@worker_processes)).to eq(2)
      expect(udp_server.instance_variable_get(:@worker_processes)).to eq(2)
      expect(warnings).to be_empty
    end

    it 'accepts a per-protocol alias that restates the written global count (GUARD)' do
      udp_server, tcp_server = built_for_processes(%i[udp tcp],
                                                   protocol_settings: { udp: { processes: 3 }, tcp: { processes: 3 } },
                                                   processes: 3, written: [:processes])

      expect(udp_server.instance_variable_get(:@worker_processes)).to eq(3)
      expect(tcp_server.instance_variable_get(:@worker_processes)).to eq(3)
      expect(warnings).to be_empty
    end

    it 'raises for two per-protocol counts that disagree (PROOF 2)' do
      allow(config).to receive(:protocol_settings).and_return(udp: { processes: 2 }, tcp: { processes: 3 })
      allow(config).to receive(:processes).and_return(1)
      written_keys_stub

      expect { lifecycle.send(:build_servers, %i[udp tcp], 0) }.to raise_error(ArgumentError) do |error|
        expect(error.message).to include('ONE worker count')
        expect(error.message).to include('protocol_settings[:udp][:processes] = 2')
        expect(error.message).to include('protocol_settings[:tcp][:processes] = 3')
      end
    end

    it 'raises when a written global count and a per-protocol alias disagree (PROOF)' do
      allow(config).to receive(:protocol_settings).and_return(tcp: { processes: 2 })
      allow(config).to receive(:processes).and_return(4)
      written_keys_stub(:processes)

      expect { lifecycle.send(:build_servers, %i[udp tcp], 0) }.to raise_error(ArgumentError) do |error|
        expect(error.message).to include('ONE worker count')
        expect(error.message).to include('the top-level `processes` = 4')
        expect(error.message).to include('protocol_settings[:tcp][:processes] = 2')
      end
    end

    it 'raises before it builds anything, so a disagreeing config never boots (GUARD)' do
      allow(config).to receive(:protocol_settings).and_return(udp: { processes: 2 }, tcp: { processes: 3 })
      expect(Takagi::Server::Registry).not_to receive(:build)

      expect { lifecycle.send(:build_servers, %i[udp tcp], 0) }.to raise_error(ArgumentError)
    end

    it 'raises nothing and warns nothing when no processes key was written (GUARD B)' do
      udp_server, tcp_server = built_for_processes(%i[udp tcp], protocol_settings: {}, processes: 1)

      expect(udp_server.instance_variable_get(:@worker_processes)).to eq(1)
      expect(tcp_server.instance_variable_get(:@worker_processes)).to eq(1)
      expect(warnings).to be_empty
    end
  end

  describe 'the UDP transport keeps working the same way (GUARDS)' do
    it 'keeps consuming the global processes count without warning' do
      server = configured_processes(:udp, protocol_settings: {}, global_processes: 4)

      expect(server.instance_variable_get(:@worker_processes)).to eq(4)
      expect(warnings).to be_empty
    end

    it 'takes a lone per-protocol count as the service count when the global key is unwritten' do
      server = configured_processes(:udp, protocol_settings: { udp: { processes: 2 } }, global_processes: 4)

      expect(server.instance_variable_get(:@worker_processes)).to eq(2)
      expect(warnings).to be_empty
    end

    it 'still receives max_connections alongside its worker count' do
      allow(config).to receive(:max_connections).and_return(50)
      server = configured_processes(:udp, protocol_settings: { udp: { processes: 2 } }, global_processes: 1)

      expect(server).to be_a(Takagi::Server::Udp)
      expect(server.instance_variable_get(:@worker_processes)).to eq(2)
      expect(server.instance_variable_get(:@worker_threads)).to eq(1)
    end
  end

  # Row 8 of .omo/plans/tcp-multi-worker.md: one concurrency vocabulary, stated per key, with
  # per-layer precedence and loud validation. Every example drives the resolution site
  # (`build_servers`), so the values and warnings asserted here are the ones a server is built
  # with, and the raise happens before any server is instantiated.
  describe 'the concurrency vocabulary (row 8)' do
    def built_servers(protocols, protocol_settings:, threads: 1, processes: 1, max_connections: nil, written: [])
      allow(config).to receive_messages(
        protocol_settings: protocol_settings,
        threads: threads,
        processes: processes,
        max_connections: max_connections
      )
      written_keys_stub(*written)
      lifecycle.send(:build_servers, protocols, 0).tap { |built| servers.concat(built) }
    end

    it 'raises for a per-protocol max_connections its target cannot apply (PROOF, criterion d)' do
      allow(config).to receive(:protocol_settings).and_return(udp: { max_connections: 2 })

      # Row 31 of .omo/plans/tcp-multi-worker.md: the "no server was built" half used to be
      # `expect(servers).to be_empty`, which CANNOT fail - `servers` is the spec-local array this
      # example never populates, so it is empty whatever `build_servers` does (mutation M12c
      # instantiated a server before the raise and the example still passed 30/0). Guard the real
      # build entry point `build_servers` reaches (`Server::Registry.build`, server_lifecycle.rb:161).
      expect(Takagi::Server::Registry).not_to receive(:build)

      # Row 35 of .omo/plans/tcp-multi-worker.md: the guard above pins the construction CALL's
      # name, not the absence of a server OBJECT - a refactor routing instantiation through
      # `Server::Registry.get(protocol).new(**options)` (measured mutant cc957b4a) builds a real
      # server while `build` is never called, and the example still passed. So also assert that
      # the class the registry ACTUALLY resolves for this protocol is never instantiated.
      expect(Takagi::Server::Registry.get(:udp)).not_to receive(:new)

      expect { lifecycle.send(:build_servers, [:udp], 0) }.to raise_error(ArgumentError) do |error|
        expect(error.message).to include('max_connections')
        expect(error.message).to include('protocol_settings[:udp]')
        expect(error.message).to include('accepts no connections')
        expect(error.message).to include('protocol_settings: { tcp: { max_connections: <N> } }')
      end
    end

    it 'rejects the inapplicable key even when its own protocol is not the one being built (PROOF)' do
      allow(config).to receive(:protocol_settings).and_return(udp: { max_connections: 2 })

      expect { lifecycle.send(:build_servers, [:tcp], 0) }.to raise_error(ArgumentError, /max_connections/)
    end

    it 'still applies a per-protocol max_connections to its TCP target, silently (GUARD)' do
      server = built_servers([:tcp], protocol_settings: { tcp: { max_connections: 8 } }).first

      expect(server.instance_variable_get(:@max_connections)).to eq(8)
      expect(warnings).to be_empty
    end

    it 'warns once for a global max_connections no UDP target can take (PROOF, criterion e)' do
      udp_server, tcp_server = built_servers([:udp, :tcp], protocol_settings: {}, max_connections: 100)

      expect(warnings.size).to eq(1)
      expect(warnings.first).to include('max_connections')
      expect(warnings.first).to include(':udp')
      expect(warnings.first).to include('protocol_settings: { tcp: { max_connections: 100 } }')
      expect(warnings.first).not_to include('processes')

      # GUARD: the UDP target's behaviour is unchanged - it is still never given the key, while
      # the TCP server that CAN consume it keeps it.
      expect(udp_server).to be_a(Takagi::Server::Udp)
      expect(udp_server.instance_variable_get(:@max_connections)).to be_nil
      expect(tcp_server.instance_variable_get(:@max_connections)).to eq(100)
    end

    it 'warns once for a written global threads a TCP target does not consume (PROOF)' do
      udp_server, tcp_server = built_servers([:udp, :tcp], protocol_settings: {}, threads: 4, written: [:threads])

      expect(warnings.size).to eq(1)
      expect(warnings.first).to include('threads')
      expect(warnings.first).to include(':tcp')
      expect(warnings.first).to include('protocol_settings: { tcp: { threads: 4 } }')

      expect(udp_server.instance_variable_get(:@worker_threads)).to eq(4) # consumed here
      expect(tcp_server.instance_variable_get(:@worker_threads)).to be_nil # and not here
      expect(tcp_server.send(:pooled?)).to be(false)
    end

    it 'stays silent for the defaults nobody wrote (Must-NOT)' do
      built_servers([:udp, :tcp], protocol_settings: {})

      expect(warnings).to be_empty
      expect(Takagi.config.threads).to eq(1)
      expect(Takagi.config.max_connections).to be_nil
    end

    it 'keeps the per-protocol threads count winning over the global one for UDP (GUARD, criterion b)' do
      server = built_servers([:udp], protocol_settings: { udp: { threads: 4 } }, threads: 8).first

      expect(server.instance_variable_get(:@worker_threads)).to eq(4)
      expect(warnings).to be_empty
    end

    it 'carries a written per-protocol threads count into the TCP pool (GUARD, criterion a - row 6)' do
      server = built_servers([:tcp], protocol_settings: { tcp: { threads: 3 } }, threads: 8).first

      expect(server.instance_variable_get(:@worker_threads)).to eq(3)
      expect(server.send(:pooled?)).to be(true)
      expect(warnings).to be_empty
    end

    it 'leaves the TCP pool unset when only the global threads count applies (GUARD)' do
      server = built_servers([:tcp], protocol_settings: {}, threads: 4, written: [:threads]).first

      expect(server.instance_variable_get(:@worker_threads)).to be_nil
      expect(server.send(:pooled?)).to be(false)
      expect(warnings.size).to eq(1)
    end

    it 'sends the written global processes count to TCP with no warning (row 3 supersedes row 4s warning)' do
      server = built_servers([:tcp], protocol_settings: {}, processes: 4, written: [:processes]).first

      expect(server.instance_variable_get(:@worker_processes)).to eq(4)
      expect(warnings).to be_empty
    end
  end

  # Row 20 of .omo/plans/tcp-multi-worker.md: the trigger is the WRITTEN key's presence, so a
  # written global `threads: 1` - a count a TCP target cannot consume - is reported once, while
  # the untouched default stays silent. The presence carrier itself is pinned in config_spec.
  describe 'the written-global-threads trigger (row 20)' do
    def built_for_written(protocols, protocol_settings:, threads:, written:)
      allow(config).to receive_messages(protocol_settings: protocol_settings, threads: threads)
      written_keys_stub(*written)
      lifecycle.send(:build_servers, protocols, 0).tap { |built| servers.concat(built) }
    end

    it 'warns exactly once for a WRITTEN global threads: 1 a TCP target cannot consume (PROOF)' do
      built_for_written([:udp, :tcp], protocol_settings: {}, threads: 1, written: [:threads])

      expect(warnings.size).to eq(1)
      expect(warnings.first).to include('threads: 1')
      expect(warnings.first).to include(':tcp')
      expect(warnings.first).to include('protocol_settings: { tcp: { threads: 1 } }')
    end

    it 'stays silent when the global threads key was never written (GUARD)' do
      built_for_written([:udp, :tcp], protocol_settings: {}, threads: 1, written: [])

      expect(warnings).to be_empty
    end

    it 'still warns exactly once for a written count of 2 (GUARD)' do
      built_for_written([:tcp], protocol_settings: {}, threads: 2, written: [:threads])

      expect(warnings.size).to eq(1)
      expect(warnings.first).to include('threads: 2')
    end

    it 'reports only the threads key now that every transport consumes processes (row 3 GUARD)' do
      allow(config).to receive_messages(protocol_settings: {}, processes: 4)
      written_keys_stub(:processes, :threads)
      lifecycle.send(:build_servers, [:tcp], 0).tap { |built| servers.concat(built) }

      expect(warnings.size).to eq(1)
      expect(warnings.first).to include('`threads:')
      expect(warnings.grep(/`processes:/)).to be_empty
    end
  end

  # Row 3 of .omo/plans/unified-cluster.md: every transport now consumes `processes`, so row 24's
  # written-global warning has no premise left - the written count is APPLIED to every transport
  # instead of being reported. The presence carrier row 24 pinned still decides what counts as
  # WRITTEN (config_spec pins it), and it is what tells the untouched default apart from a written
  # count here.
  describe 'the retired written-global-processes warning (row 3)' do
    def built_for_written_processes(protocols, protocol_settings:, processes:, written:, threads: 1)
      allow(config).to receive_messages(protocol_settings: protocol_settings, threads: threads, processes: processes)
      written_keys_stub(*written)
      lifecycle.send(:build_servers, protocols, 0).tap { |built| servers.concat(built) }
    end

    it 'applies a WRITTEN global processes: 1 to every transport without a word (PROOF)' do
      udp_server, tcp_server = built_for_written_processes(%i[udp tcp], protocol_settings: {}, processes: 1,
                                                                          written: [:processes])

      expect(udp_server.instance_variable_get(:@worker_processes)).to eq(1)
      expect(tcp_server.instance_variable_get(:@worker_processes)).to eq(1)
      expect(warnings).to be_empty
    end

    it 'carries a written global count of 3 into both transports (GUARD)' do
      udp_server, tcp_server = built_for_written_processes(%i[udp tcp], protocol_settings: {}, processes: 3,
                                                                          written: [:processes])

      expect(udp_server.instance_variable_get(:@worker_processes)).to eq(3)
      expect(tcp_server.instance_variable_get(:@worker_processes)).to eq(3)
      expect(warnings).to be_empty
    end

    it 'still stays silent for the untouched default (GUARD)' do
      built_for_written_processes(%i[udp tcp], protocol_settings: {}, processes: 1, written: [])

      expect(warnings).to be_empty
    end
  end

  # Row 23 of .omo/plans/tcp-multi-worker.md: the presence carrier is process-wide state on the
  # `Takagi.config` singleton and has no reset of its own, so a process that assigns a value and
  # restores it left the key marked as WRITTEN and an unrelated later build warned about a key
  # nobody wrote in it. `Config#reset_written_keys!` is that API; the pair below is the control
  # (the hazard) and the fix, driven through the real carrier and a real build.
  describe 'the written-key carrier is resettable (row 23)' do
    def build_with_the_real_carrier
      allow(config).to receive_messages(protocol_settings: {}, threads: 1, processes: 1, max_connections: nil)
      allow(config).to receive(:written?).and_call_original
      lifecycle.send(:build_servers, [:udp, :tcp], 0).tap { |built| servers.concat(built) }
    end

    it 'warns after a value restore alone - the hazard the reset removes (control)' do
      Takagi.config.threads = 7
      Takagi.config.threads = 1 # the VALUE is back; the written flag is not

      expect(Takagi.config.written?(:threads)).to be(true)

      build_with_the_real_carrier

      expect(warnings.size).to eq(1)
      expect(warnings.first).to include(':tcp')
    end

    it 'emits no warning once the presence is reset, so an unrelated build stays quiet (PROOF)' do
      Takagi.config.threads = 7
      Takagi.config.threads = 1
      Takagi.config.reset_written_keys!

      expect(Takagi.config.written?(:threads)).to be(false)

      build_with_the_real_carrier

      expect(warnings).to be_empty
    end

    # Row 3 of .omo/plans/unified-cluster.md: a programmatic global write is no longer an
    # unconsumed key - every transport forks the one count - so it reaches both servers and warns
    # nothing. The carrier is the real singleton here, so the example hands it back (never depend
    # on spec order); the presence it records is still pinned in config_spec.
    it 'reaches BOTH transports for a programmatic processes write (row 3)' do
      Takagi.config.processes = 2
      allow(config).to receive_messages(protocol_settings: {}, max_connections: nil)
      allow(config).to receive(:written?).and_call_original

      built = lifecycle.send(:build_servers, %i[udp tcp], 0)
      servers.concat(built)

      expect(built.map { |server| server.instance_variable_get(:@worker_processes) }).to eq([2, 2])
      expect(warnings).to be_empty
    ensure
      Takagi.config.processes = 1
      Takagi.config.reset_written_keys!
    end
  end
end
