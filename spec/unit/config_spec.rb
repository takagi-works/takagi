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
end
