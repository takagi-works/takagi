# frozen_string_literal: true

require 'timeout'

RSpec.describe 'the hook contract external plugins depend on (plan row 14)' do
  def await_hook(queue, what, timeout: 5)
    Timeout.timeout(timeout) { queue.pop }
  rescue Timeout::Error
    raise "no #{what} arrived within #{timeout}s"
  end

  def probe_plugin
    @probe_plugin ||= begin
      mod = Module.new
      mod.define_singleton_method(:metadata) { { name: :contract_probe } }
      mod.define_singleton_method(:apply) { |_app, _options = {}| nil }
      mod
    end
  end

  it 'passes the payload to a |payload| block and to a zero-parameter block as ONE positional Hash, never as keywords' do
    zero_arity_calls = Queue.new
    shapes = Queue.new
    zero_arity = Takagi::Hooks.subscribe(:contract_arity_probe) { zero_arity_calls << :called }
    positional = Takagi::Hooks.subscribe(:contract_arity_probe) { |*args, **kwargs| shapes << [args, kwargs] }

    payload = { value: 42, name: :sinatra }
    Takagi::Hooks.emit(:contract_arity_probe, payload)

    expect(await_hook(zero_arity_calls, 'zero-parameter call')).to eq(:called)
    args, kwargs = await_hook(shapes, 'positional shape')
    expect(args).to eq([payload])
    expect(kwargs).to eq({})
  ensure
    Takagi::Hooks.unsubscribe(:contract_arity_probe, zero_arity)
    Takagi::Hooks.unsubscribe(:contract_arity_probe, positional)
  end

  it 'hands a |payload| block and a ->(payload) lambda the same payload object, one positional Hash each' do
    from_block = Queue.new
    from_lambda = Queue.new
    block_handler = Takagi::Hooks.subscribe(:contract_identity_probe) { |payload| from_block << payload }
    lambda_handler = Takagi::Hooks.subscribe(:contract_identity_probe, ->(payload) { from_lambda << payload })

    payload = { value: 7, name: :sinatra }
    Takagi::Hooks.emit(:contract_identity_probe, payload)

    block_seen = await_hook(from_block, 'block payload')
    lambda_seen = await_hook(from_lambda, 'lambda payload')

    expect(block_seen).to equal(payload)
    expect(lambda_seen).to equal(payload)
    expect(block_seen).to equal(lambda_seen)
  ensure
    Takagi::Hooks.unsubscribe(:contract_identity_probe, block_handler)
    Takagi::Hooks.unsubscribe(:contract_identity_probe, lambda_handler)
  end

  it 'emits :server_starting once per transport from Server::Multi#run! and :server_stopped once per transport from each transport #shutdown! for a two-transport boot' do
    started = Queue.new
    stopped = Queue.new
    starting_handler = Takagi::Hooks.subscribe(:server_starting) { |payload| started << payload }
    stopped_handler = Takagi::Hooks.subscribe(:server_stopped) { |payload| stopped << payload }

    udp = Takagi::Server::Udp.new(port: 0, worker_processes: 1, worker_threads: 1,
                                  watcher: Takagi::Observer::Watcher.new(interval: 60))
    tcp = Takagi::Server::Tcp.new(port: 0, worker_processes: 1, worker_threads: 1,
                                  watcher: Takagi::Observer::Watcher.new(interval: 60))
    ports = { udp: udp.bound_port, tcp: tcp.bound_port }
    service = Takagi::Server::Multi.new([udp, tcp], protocols: %i[udp tcp])
    service_thread = Thread.new { service.run! }

    booted = [await_hook(started, 'first :server_starting'), await_hook(started, 'second :server_starting')]
    expect(booted.map { |payload| payload[:protocol] }).to contain_exactly(:udp, :tcp)
    expect(booted.to_h { |payload| [payload[:protocol], payload[:port]] }).to eq(ports)
    expect(started).to be_empty

    service.shutdown!
    service_thread.join(10)

    halted = [await_hook(stopped, 'first :server_stopped'), await_hook(stopped, 'second :server_stopped')]
    expect(halted.map { |payload| payload[:protocol] }).to contain_exactly(:udp, :tcp)
    expect(halted.to_h { |payload| [payload[:protocol], payload[:port]] }).to eq(ports)
    expect(stopped).to be_empty
  ensure
    service&.shutdown!
    service_thread&.join(10)
    Takagi::Hooks.unsubscribe(:server_starting, starting_handler)
    Takagi::Hooks.unsubscribe(:server_stopped, stopped_handler)
  end

  it 'delivers a hook emitted inside a forked child in that child, and a hook emitted in the parent in the parent' do
    parent_seen = Queue.new
    parent_handler = Takagi::Hooks.subscribe(:contract_fork_probe) { |payload| parent_seen << [Process.pid, payload] }
    reader, writer = IO.pipe

    child_pid = fork do
      reader.close
      Takagi::Bus.shutdown
      child_seen = Queue.new
      Takagi::Hooks.subscribe(:contract_fork_probe) { |payload| child_seen << payload }
      Takagi::Hooks.emit(:contract_fork_probe, value: 99)
      observed = begin
        Timeout.timeout(5) { child_seen.pop }
      rescue Timeout::Error
        :nothing_arrived
      end
      writer.write(Marshal.dump([Process.pid, observed]))
      writer.close
      exit!(0)
    end

    writer.close
    Takagi::Hooks.emit(:contract_fork_probe, value: 11)
    parent_pid_seen, parent_payload = await_hook(parent_seen, 'parent delivery')
    report = Timeout.timeout(15) { reader.read }
    reader.close
    Process.wait(child_pid)
    child_pid_reported, child_payload = Marshal.load(report)

    expect(parent_pid_seen).to eq(Process.pid)
    expect(parent_payload).to eq(value: 11)
    expect(child_pid).not_to eq(Process.pid)
    expect(child_pid_reported).to eq(child_pid)
    expect(child_payload).to eq(value: 99)
  ensure
    Takagi::Hooks.unsubscribe(:contract_fork_probe, parent_handler)
    if child_pid
      begin
        Process.waitpid(child_pid)
      rescue Errno::ECHILD
        nil
      end
    end
  end

  it 'carries the :plugin_enabled name as a Symbol on the enable path the devtools plugin matches' do
    enabled = Queue.new
    handler = Takagi::Hooks.subscribe(:plugin_enabled) { |payload| enabled << payload }

    Takagi::Plugin.unregister(:contract_probe)
    info = Takagi::Plugin.register(probe_plugin)
    Takagi::Plugin.enable(info.name, app: Object.new)
    payload = await_hook(enabled, ':plugin_enabled payload')

    expect(info.name).to eq(:contract_probe)
    expect(payload[:name]).to eq(:contract_probe)
    expect(payload[:name]).to be_a(Symbol)
    expect(payload[:metadata]).to eq(name: :contract_probe)
  ensure
    Takagi::Plugin.unregister(:contract_probe)
    Takagi::Hooks.unsubscribe(:plugin_enabled, handler)
  end
end
