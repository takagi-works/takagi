# frozen_string_literal: true

# A reactor OWNS its pool. The pool object survives a `fork` but its threads do not, so every
# schedule site goes through `Reactor#schedule_in_pool`, which asks
# `ThreadPool#running_in_this_process?` first and, in a forked child, runs the observer work in
# the calling thread instead of pushing it into a queue whose drainer died.
RSpec.describe Takagi::Observable::Reactor do
  let(:path) { '/reactor-pool-probe' }

  before do
    Takagi::Observer::Registry.subscriptions.clear
  end

  after do
    @reactor&.thread_pool&.shutdown
    Takagi::Observer::Registry.subscriptions.clear
  end

  def pooled_reactor(reporter)
    reactor_class = Class.new(described_class)
    reactor_class.configure { threads 2 }
    @reactor = reactor_class.new
    Takagi::Observer::Registry.subscribe(path, handler: reporter)
    @reactor
  end

  it 'delivers through its own pool in the process that owns it (GUARD)' do
    reader, writer = IO.pipe
    reactor = pooled_reactor(proc { |value, _| writer.write("handler:#{value}") })

    expect(reactor.thread_pool.running_in_this_process?).to be(true)

    reactor.notify(path, 'parent')

    expect(IO.select([reader], nil, nil, 5)).not_to be_nil, 'the pool never delivered the notification'
    expect(reader.read_nonblock(256)).to include('handler:parent')
  ensure
    reader&.close
    writer&.close
  end

  # The executing thread is asserted by identity AND by the pool's own worker-name convention,
  # so "the pool ran it" is never inferred from timing. Bounded wait, no sleep.
  it 'executes the notification on a POOL thread, not the caller, when the pool lives here (PROOF)' do
    reader, writer = IO.pipe
    caller_thread = Thread.current
    reactor = pooled_reactor(lambda { |value, _|
      writer.write("handler:#{value}|thread:#{Thread.current.object_id}|name:#{Thread.current.name}|done")
    })
    pool = reactor.thread_pool
    worker_name_prefix = "#{pool.name}-worker-"

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
    reactor = pooled_reactor(proc { |value, _| writer.write("handler:#{value}") })
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
