# frozen_string_literal: true

# Row 26 of .omo/plans/tcp-multi-worker.md: a reactor with an associated controller shares that
# controller's pool OBJECT (`Observable::Reactor` stores `controller.thread_pool`), and a forked
# child inherits the object with its threads already gone (threads do not survive `fork`). A plain
# `ThreadPool#schedule` there pushes the notification into a queue whose drainer died, so
# `reactor.notify` inside a worker process used to vanish without a trace and its side effect never
# happened - measured by row 13's verifier. Every schedule site now goes through
# `Reactor#schedule_in_pool`, which asks `ThreadPool#running_in_this_process?` first and, when the
# pool belongs to another process, runs the observer work in the calling thread instead - the same
# answer a forked UDP worker gives a request (`udp_worker.rb:118-126`).
RSpec.describe Takagi::Observable::Reactor do
  let(:path) { '/reactor-pool-probe' }

  before do
    Takagi::Observer::Registry.subscriptions.clear
  end

  after do
    Takagi::Observer::Registry.subscriptions.clear
  end

  # A reactor that shares its controller's pool, plus a local observer that reports every call.
  def shared_pool_reactor(reporter)
    controller = Class.new(Takagi::Controller)
    stub_const('ReactorPoolProbeController', controller)
    reactor_class = Class.new(described_class)
    reactor_class.configure { inherit_from(controller) }
    reactor = reactor_class.new
    Takagi::Observer::Registry.subscribe(path, handler: reporter)
    reactor
  end

  it 'still delivers through the pool in the process that owns it (GUARD)' do
    reader, writer = IO.pipe
    reactor = shared_pool_reactor(proc { |value, _| writer.write("handler:#{value}") })

    expect(reactor.shared_pool?).to be(true)

    reactor.notify(path, 'parent')

    expect(IO.select([reader], nil, nil, 5)).not_to be_nil, 'the pool never delivered the notification'
    expect(reader.read_nonblock(256)).to include('handler:parent')
  ensure
    reader&.close
    writer&.close
  end

  # Row 28 of .omo/plans/tcp-multi-worker.md: the guard's OTHER half. `schedule_in_pool` asks
  # `running_in_this_process?` and, when the pool lives here, hands the work to the pool - so
  # mutating the guard to ALWAYS run the block inline would ship green without this example.
  # The executing thread is asserted by identity AND by the pool's own worker-name convention,
  # so "the pool ran it" is never inferred from timing. Bounded wait, no sleep.
  it 'executes the notification on a POOL thread, not the caller, when the pool lives here (PROOF)' do
    reader, writer = IO.pipe
    caller_thread = Thread.current
    reactor = shared_pool_reactor(lambda { |value, _|
      writer.write("handler:#{value}|thread:#{Thread.current.object_id}|name:#{Thread.current.name}|done")
    })
    pool = reactor.thread_pool
    worker_name_prefix = "#{pool.name}-worker-"

    expect(reactor.shared_pool?).to be(true)
    expect(pool.running_in_this_process?).to be(true)

    reactor.notify(path, 'parent')

    expect(IO.select([reader], nil, nil, 5)).not_to be_nil, 'the pool never delivered the notification'
    payload = reader.read_nonblock(4096)

    expect(payload).to include('handler:parent')
    expect(payload).to end_with('|done')
    on_thread_id = payload[/thread:(\d+)/, 1].to_i
    on_thread_name = payload[/name:([^|]*)/, 1]
    expect(on_thread_id).not_to eq(caller_thread.object_id), 'the caller ran the observer work inline'
    expect(on_thread_name).to start_with(worker_name_prefix), 'the work did not run on a pool thread'
  ensure
    reader&.close
    writer&.close
  end

  it 'runs the observer work in the calling thread in a forked child, whose pool is dead (PROOF)' do
    reader, writer = IO.pipe
    reactor = shared_pool_reactor(proc { |value, _| writer.write("handler:#{value}") })
    pool = reactor.thread_pool

    pid = fork do
      reader.close
      begin
        writer.write("pool_running:#{pool.running_in_this_process?}")
        reactor.notify(path, 'child')
      ensure
        writer.write('|end')
        writer.close
      end
      exit!(0)
    end
    writer.close
    payload = IO.select([reader], nil, nil, 5) ? reader.read : ''
    Process.wait(pid)

    expect(payload).to start_with('pool_running:false')
    expect(payload).to include('handler:child')
    expect(payload).to end_with('|end')
    expect(pool.queue_size).to eq(0)
  ensure
    reader&.close
  end
end
