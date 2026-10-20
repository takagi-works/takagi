# frozen_string_literal: true

require 'spec_helper'
require 'timeout'

# `Bus#shutdown` stops the executor and clears subscribers without becoming
# terminal: the instance serves a later `consumer`/`publish` by rebuilding the
# executor lazily (row 10 of .omo/plans/local-bus.md).
#
# Two measurements shape these examples. (1) The failure is ASYNC-ONLY: `publish`
# has been synchronous since row 2 and never touches the executor, so a
# SYNCHRONOUS subscriber already delivered after `shutdown` on the unfixed tree
# - the last example is that control. (2) The failure needs an executor to have
# EXISTED before `shutdown`: with `@executor` still nil, the unfixed `shutdown`
# is a no-op and the next async delivery simply builds one, so that arm is a
# guard rather than a proof. With a warm executor, the unfixed tree keeps the
# dead object, `ensure_executor` hands it out, and `post` raises
# `RuntimeError: Executor is shutdown` - which is what the first example pins.
RSpec.describe 'Takagi::Bus shutdown recovery' do
  let(:bus) { Takagi::Bus.new }

  after { bus.shutdown }

  it 'serves an asynchronous delivery after shutdown' do
    warm = Queue.new
    bus.consumer('before.shutdown', async: true) { |msg| warm << msg.body[:seq] }
    bus.publish('before.shutdown', { seq: 0 })

    expect(Timeout.timeout(5) { warm.pop }).to eq(0)

    bus.shutdown

    received = Queue.new
    bus.consumer('after.shutdown', async: true) { |msg| received << msg.body[:seq] }

    bus.publish('after.shutdown', { seq: 1 })

    expect(Timeout.timeout(5) { received.pop }).to eq(1)
  end

  it 'stops the executor it drops, and rebuilds a different one on demand' do
    bus.consumer('warm.up', async: true) { |msg| bus.publish('warmed', msg.body) }
    bus.publish('warm.up', { seq: 0 })

    dead_executor = bus.executor
    expect(dead_executor).to be_a(Takagi::EventBus::AsyncExecutor::ThreadExecutor)
    expect(dead_executor.running?).to be(true)

    bus.shutdown

    expect(dead_executor.running?).to be(false), 'shutdown must stop the executor'
    expect(bus.executor).to be_nil, 'shutdown must drop the dead executor, not keep handing it out'

    received = Queue.new
    bus.consumer('after.shutdown.rebuild', async: true) { |msg| received << msg.body[:seq] }
    bus.publish('after.shutdown.rebuild', { seq: 1 })

    expect(Timeout.timeout(5) { received.pop }).to eq(1)

    rebuilt = bus.executor
    expect(rebuilt).to be_a(Takagi::EventBus::AsyncExecutor::ThreadExecutor)
    expect(rebuilt).not_to equal(dead_executor)
    expect(rebuilt.running?).to be(true)
  end

  it 'clears subscribers registered before shutdown' do
    bus.consumer('cleared.before') { |_msg| raise 'a subscriber from before shutdown must not run' }
    bus.consumer('cleared.before') { |_msg| raise 'a subscriber from before shutdown must not run' }

    expect(bus.handler_count('cleared.before')).to eq(2)

    bus.shutdown

    expect(bus.addresses).to be_empty
    expect(bus.instance_variable_get(:@consumers)).to be_empty
    expect(bus.handler_count('cleared.before')).to eq(0)
  end

  it 'keeps a synchronous subscriber delivering after shutdown (the control)' do
    bus.shutdown

    received = []
    bus.consumer('sync.after.shutdown') { |msg| received << msg.body[:seq] }

    bus.publish('sync.after.shutdown', { seq: 1 })

    expect(received).to eq([1])
  end
end
