# frozen_string_literal: true

require 'tempfile'

RSpec.describe Takagi::Config do
  let(:config) { described_class.new }
  let(:tmpfile) { Tempfile.new('takagi-config') }

  after do
    tmpfile.close!
  end

  def write_config(contents)
    tmpfile.rewind
    tmpfile.write(contents)
    tmpfile.flush
    config.load_file(tmpfile.path)
  end

  describe '#load_file' do
    it 'prefers the processes key over the legacy process key' do
      write_config <<~YAML
        processes: 4
        process: 1
      YAML

      expect(config.processes).to eq(4)
    end

    it 'falls back to legacy process key when processes is absent' do
      write_config <<~YAML
        process: 3
      YAML

      expect(config.processes).to eq(3)
    end

    it 'rejects unsafe YAML objects' do
      tmpfile.rewind
      tmpfile.write("foo: !ruby/object:Object {}\n")
      tmpfile.flush

      expect { config.load_file(tmpfile.path) }.to raise_error(Psych::DisallowedClass)
    end
  end

  describe 'logger configuration' do
    it 'applies logger level and output settings' do
      write_config <<~YAML
        logger:
          level: warn
          output: stdout
      YAML

      logger = config.logger
      internal_logger = logger.instance_variable_get(:@logger)
      expect(logger).to be_a(Takagi::Logger)
      expect(internal_logger.level).to eq(::Logger::WARN)
    end
  end

  describe 'per-protocol settings' do
    it 'parses protocol_settings overrides' do
      write_config <<~YAML
        protocol_settings:
          udp:
            processes: 8
            threads: 4
          tcp:
            threads: 50
            max_connections: 100
      YAML

      expect(config.protocol_settings[:udp]).to eq(processes: 8, threads: 4)
      expect(config.protocol_settings[:tcp]).to eq(threads: 50, max_connections: 100)
    end

    it 'defaults to an empty hash' do
      expect(config.protocol_settings).to eq({})
    end
  end

  # Row 8 of .omo/plans/tcp-multi-worker.md: parsing is shape-only. Whether a written
  # per-protocol key can apply to its target is checked where the servers are built
  # (`ServerLifecycle#build_servers`), because that is where the value would be handed over.
  describe 'protocol_settings applicability' do
    it 'parses a per-protocol key its target cannot apply, leaving the rejection to the boot' do
      write_config <<~YAML
        protocol_settings:
          udp:
            max_connections: 4
      YAML

      expect(config.protocol_settings[:udp]).to eq(max_connections: 4)
    end

    it 'keeps a per-protocol key that does apply to its target unchanged' do
      write_config <<~YAML
        protocol_settings:
          tcp:
            threads: 4
            max_connections: 16
      YAML

      expect(config.protocol_settings[:tcp]).to eq(threads: 4, max_connections: 16)
    end
  end

  # Row 20 of .omo/plans/tcp-multi-worker.md: the global-`threads` warning keys off whether the
  # key was WRITTEN, not off the value it happens to hold, so Config carries written-key presence.
  # A YAML key and a programmatic assignment both count; the defaults `set_server_defaults`
  # assigns directly never do.
  describe 'written-key presence' do
    it 'reports a written global threads key whatever its value (PROOF, row 20)' do
      write_config "threads: 1\n"

      expect(config.written?(:threads)).to be(true)
    end

    it 'does not report a key the YAML never wrote (PROOF, row 20)' do
      write_config "port: 5683\n"

      expect(config.written?(:threads)).to be(false)
    end

    it 'does not report the untouched default (GUARD, row 20)' do
      expect(described_class.new.written?(:threads)).to be(false)
    end

    it 'reports a programmatic assignment, so no written count goes unreported (GUARD, row 20)' do
      config.threads = 4

      expect(config.written?(:threads)).to be(true)
    end

    # Row 29 of .omo/plans/tcp-multi-worker.md: `processes=` records presence exactly like
    # `threads=` now. It used to be a bare `attr_accessor`, so a programmatic write of a global
    # count a TCP target cannot consume was accepted in silence, while the same key written in
    # YAML was reported.
    it 'reports a programmatic processes assignment too (PROOF, row 29)' do
      config.processes = 1

      expect(config.written?(:processes)).to be(true)
      expect(config.processes).to eq(1)
    end

    it 'still leaves the untouched processes default unreported (GUARD, row 29)' do
      expect(described_class.new.written?(:processes)).to be(false)
    end

    it 'still carries the written value into the reader unchanged (GUARD, row 20)' do
      write_config "threads: 6\n"

      expect(config.threads).to eq(6)
    end
  end

  # Row 23 of .omo/plans/tcp-multi-worker.md: presence is carrier state that the boot warnings
  # read, so a process that assigns a value and restores it must be able to put the presence back
  # as well - `reset_written_keys!` is that API. Without it the suite's order-independence rested
  # on stubbing `written?` away, which is a mask rather than a property.
  describe 'resetting written-key presence (row 23)' do
    it 'forgets presence so a restored value cannot be reported as written (PROOF)' do
      config.threads = 2
      config.threads = 1 # restores the VALUE only, which is what a spec's teardown does today
      expect(config.written?(:threads)).to be(true)

      config.reset_written_keys!

      expect(config.written?(:threads)).to be(false)
    end

    it 'forgets the processes presence the YAML path records too (PROOF, row 24)' do
      write_config "processes: 4\n"
      expect(config.written?(:processes)).to be(true)

      config.reset_written_keys!

      expect(config.written?(:processes)).to be(false)
    end

    it 'leaves the values it carries untouched (GUARD)' do
      write_config "processes: 4\nthreads: 6\n"

      config.reset_written_keys!

      expect(config.processes).to eq(4)
      expect(config.threads).to eq(6)
    end
  end

  # Row 24 of .omo/plans/tcp-multi-worker.md: `processes` reaches the presence carrier through
  # its own assignment path (`assign_processes`, which bypasses `assign_setting`) and through the
  # legacy `process` alias, so presence must be recorded on both keys' write.
  describe 'processes presence through the YAML path (row 24)' do
    it 'reports the processes key whatever its value, including the default (PROOF)' do
      write_config "processes: 1\n"

      expect(config.written?(:processes)).to be(true)
      expect(config.processes).to eq(1)
    end

    it 'reports the legacy process alias as a written count too (PROOF)' do
      write_config "process: 3\n"

      expect(config.written?(:processes)).to be(true)
      expect(config.processes).to eq(3)
    end

    it 'does not report a key the YAML never wrote (GUARD)' do
      write_config "port: 5683\n"

      expect(config.written?(:processes)).to be(false)
    end

    it 'does not report the untouched default (GUARD)' do
      expect(described_class.new.written?(:processes)).to be(false)
    end
  end

  describe 'block-wise settings' do
    it 'defaults to safe block-wise values' do
      expect(config.block_wise.szx).to eq(6)
      expect(config.block_wise.max_assembled_bytes).to eq(1_048_576)
      expect(config.block_wise.assembly_ttl).to eq(30)
      expect(config.block_wise.max_concurrent_assemblies).to eq(64)
      expect(config.block_wise.enabled).to be(true)
    end

    it 'parses a block_wise block' do
      write_config <<~YAML
        block_wise:
          szx: 4
          max_assembled_bytes: 4096
          assembly_ttl: 5
          max_concurrent_assemblies: 8
          enabled: false
      YAML

      expect(config.block_wise.szx).to eq(4)
      expect(config.block_wise.max_assembled_bytes).to eq(4096)
      expect(config.block_wise.assembly_ttl).to eq(5)
      expect(config.block_wise.max_concurrent_assemblies).to eq(8)
      expect(config.block_wise.enabled).to be(false)
    end

    it 'rejects an out-of-range szx' do
      expect do
        write_config <<~YAML
          block_wise:
            szx: 9
        YAML
      end.to raise_error(ArgumentError, /szx/)
    end
  end

  # Row 1 of .omo/plans/coap-proxy.md. Parsing is shape-only here, exactly as `protocol_settings`
  # is: whether a prefix is absolute and unique, and whether a route points back at the proxy
  # itself, is `Takagi::Proxy::RouteTable`'s boot validation (spec/unit/proxy/route_table_spec.rb).
  describe 'proxy settings' do
    it 'defaults to a disabled section that refuses to forward and answers discovery locally (PROOF, row 1)' do
      expect(config.proxy.enabled).to be(false)
      expect(config.proxy.routes).to eq([])
      expect(config.proxy.names).to eq([])
      expect(config.proxy.discovery).to eq(:local)
      expect(config.proxy.forward).to eq(:deny)
    end

    it 'parses a proxy block into routes, names, discovery and forward (PROOF, row 1)' do
      write_config <<~YAML
        proxy:
          enabled: true
          discovery: aggregate
          forward: configured
          names:
            - localhost
            - "127.0.0.1:5683"
          routes:
            - prefix: /sensors
              host: 10.0.0.1
              port: 5683
            - prefix: /admin
              host: 10.0.0.2
              port: 9999
              outbound: tcp
      YAML

      proxy = config.proxy
      expect(proxy.enabled).to be(true)
      expect(proxy.discovery).to eq(:aggregate)
      expect(proxy.forward).to eq(:configured)
      expect(proxy.names).to eq(['localhost', '127.0.0.1:5683'])
      expect(proxy.routes.map(&:prefix)).to eq(['/sensors', '/admin'])
      expect(proxy.routes.map(&:host)).to eq(['10.0.0.1', '10.0.0.2'])
      expect(proxy.routes.first.port).to eq(5683)
      expect(proxy.routes.first.outbound).to be_nil
      expect(proxy.routes.last.outbound).to eq(:tcp)
    end

    it 'keeps the defaults for a YAML that writes no proxy block at all (PROOF, row 1)' do
      write_config "port: 5684\n"

      expect(config.proxy.enabled).to be(false)
      expect(config.proxy.routes).to eq([])
      expect(config.proxy.forward).to eq(:deny)
    end

    it 'rejects an unknown discovery mode (PROOF, row 1)' do
      expect { write_config "proxy:\n  discovery: cache\n" }.to raise_error(ArgumentError, /discovery/)
    end

    it 'rejects an unknown forward mode (PROOF, row 1)' do
      expect { write_config "proxy:\n  forward: open\n" }.to raise_error(ArgumentError, /forward/)
    end
  end

  # Row 12 of .omo/plans/local-bus.md: the `event_bus` section advertises only the keys a live
  # consumer reads. A key whose feature was removed must RAISE, naming itself and its own reason,
  # rather than be accepted into a struct nobody reads.
  describe 'event_bus settings (row 12)' do
    it 'raises for a key this row removed, naming it (PROOF, row 12)' do
      expect { write_config "event_bus:\n  state_cache_size: 1000\n" }
        .to raise_error(ArgumentError, /state_cache_size/)
    end

    it 'raises for every key this row removed (PROOF, row 12)' do
      %w[state_cache_size state_cache_ttl message_buffering_enabled
         message_buffer_max_messages message_buffer_ttl].each do |key|
        expect { write_config "event_bus:\n  #{key}: 1\n" }
          .to raise_error(ArgumentError, /#{key}/), "expected a refusal for #{key}"
      end
    end

    it 'gives each refused key its own reason, not one shared sentence (PROOF, row 12)' do
      expect { write_config "event_bus:\n  state_cache_size: 1000\n" }
        .to raise_error(ArgumentError, /state_cache_size \(the bus no longer retains per-address state\)/)
      expect { write_config "event_bus:\n  message_buffer_ttl: 300\n" }
        .to raise_error(ArgumentError, /message_buffer_ttl \(bus message buffering was removed\)/)
    end

    it 'still refuses row 8 keys (GUARD, row 12)' do
      %w[ractors process_pool_size].each do |key|
        expect { write_config "event_bus:\n  #{key}: 1\n" }
          .to raise_error(ArgumentError, /#{key}/), "expected a refusal for #{key}"
      end
    end

    it 'loads a surviving key (GUARD, row 12)' do
      write_config "event_bus:\n  async_threads: 4\n"

      expect(config.event_bus.async_threads).to eq(4)
    end

    it 'carries async_backlog_limit from YAML, not only the environment (PROOF, row 12)' do
      write_config "event_bus:\n  async_backlog_limit: 7\n"

      expect(config.event_bus.async_backlog_limit).to eq(7)
    end

    it 'defaults the backlog bound to the executor bound (GUARD, row 12)' do
      expect(described_class.new.event_bus.async_backlog_limit)
        .to eq(Takagi::Bus::AsyncExecutor::ThreadExecutor::DEFAULT_BACKLOG_LIMIT)
    end

    it 'keeps the cleanup keys the registry reads (GUARD, row 12)' do
      write_config "event_bus:\n  cleanup_interval: 5\n  max_observer_age: 30\n"

      expect(config.event_bus.cleanup_interval).to eq(5)
      expect(config.event_bus.max_observer_age).to eq(30)
    end
  end
end
