# frozen_string_literal: true

require 'spec_helper'
require 'timeout'

class AsyncExecutorSpecHandler
  attr_reader :address, :consumer_id

  def initialize(address: 'spec.address', consumer_id: 'consumer-1', &block)
    @address = address
    @consumer_id = consumer_id
    @block = block
  end

  def call(message)
    @block.call(message)
  end
end

RSpec.describe Takagi::Bus::AsyncExecutor::ThreadExecutor do
  let(:executor) { described_class.new(size: 2) }
  let(:release) { Queue.new }

  after do
    3.times { release << :go }
    executor.shutdown
  end

  def next_within(queue, seconds = 5)
    Timeout.timeout(seconds) { queue.pop }
  end

  def nothing_within?(queue, seconds)
    Timeout.timeout(seconds) { queue.pop }
    false
  rescue Timeout::Error
    true
  end

  describe '#initialize' do
    it 'creates a pool with at least one worker' do
      small = described_class.new(size: 0)
      expect(small.size).to eq(1)
      small.shutdown
    end

    it 'creates a pool with the requested size' do
      larger = described_class.new(size: 5)
      expect(larger.size).to eq(5)
      larger.shutdown
    end
  end

  describe '#post' do
    it 'runs the work on a pool thread rather than the caller' do
      done = Queue.new
      executor.post(AsyncExecutorSpecHandler.new { |_msg| done << Thread.current.name }, :job)

      expect(next_within(done)).to start_with('EventBus-ThreadExecutor-')
    end

    it 'delivers every one of many messages' do
      done = Queue.new
      10.times { |i| executor.post(AsyncExecutorSpecHandler.new { |msg| done << msg }, i) }

      expect(Array.new(10) { next_within(done) }.sort).to eq((0..9).to_a)
    end

    it 'processes a large batch' do
      done = Queue.new
      100.times { |i| executor.post(AsyncExecutorSpecHandler.new { |msg| done << msg }, i) }

      expect(Array.new(100) { next_within(done) }.sort).to eq((0..99).to_a)
    end

    it 'keeps running after a handler raises' do
      done = Queue.new
      executor.post(AsyncExecutorSpecHandler.new { |_msg| raise 'boom' }, :broken)
      executor.post(AsyncExecutorSpecHandler.new { |msg| done << msg }, :after)

      expect(next_within(done)).to eq(:after)
      expect(executor.running?).to be(true)
    end

    it 'raises when the executor is shutdown' do
      executor.shutdown

      expect { executor.post(AsyncExecutorSpecHandler.new { :ok }, :work) }.to raise_error('Executor is shutdown')
    end

    it 'refuses a message that would exceed the backlog, naming the subscriber' do
      small = described_class.new(size: 1, backlog_limit: 1)
      started = Queue.new
      gate = Queue.new
      handler = AsyncExecutorSpecHandler.new(address: 'overflow.address', consumer_id: 'overflow-1') do |msg|
        started << msg
        gate.pop if msg == 1
      end

      expect(small.post(handler, 1)).to be(true)
      expect(next_within(started)).to eq(1)
      expect(small.post(handler, 2)).to be(true)
      expect(Takagi.logger).to receive(:warn).with(/backlog full \(1\) for subscriber overflow\.address \(overflow-1\)/)
      expect(small.post(handler, 3)).to be(false)
      expect(small.stats).to include(backlog_limit: 1, in_flight: 1, queued: 1, refused: 1)
    ensure
      gate << :go
      small&.shutdown
    end
  end

  describe 'one subscriber at a time' do
    it 'keeps a subscriber ordered and never concurrent with itself' do
      started = Queue.new
      finished = Queue.new
      in_flight = 0
      max_in_flight = 0
      lock = Mutex.new
      handler = AsyncExecutorSpecHandler.new do |msg|
        lock.synchronize do
          in_flight += 1
          max_in_flight = in_flight if in_flight > max_in_flight
        end
        started << msg
        release.pop if msg == 1
        lock.synchronize { in_flight -= 1 }
        finished << msg
      end

      executor.post(handler, 1)
      executor.post(handler, 2)

      expect(next_within(started)).to eq(1)
      expect(nothing_within?(started, 0.3)).to be(true), 'a second delivery started while the first was in flight'
      release << :go
      expect(next_within(started)).to eq(2)
      expect(Array.new(2) { next_within(finished) }).to eq([1, 2])
      expect(lock.synchronize { max_in_flight }).to eq(1)
    end

    it 'lets two different subscribers run at the same time' do
      started = Queue.new
      first = AsyncExecutorSpecHandler.new do |msg|
        started << msg
        release.pop
      end
      second = AsyncExecutorSpecHandler.new do |msg|
        started << msg
        release.pop
      end

      executor.post(first, :first)
      executor.post(second, :second)

      expect([next_within(started), next_within(started)].sort).to eq(%i[first second])
      release << :go
      release << :go
    end
  end

  describe '#shutdown' do
    it 'stops the workers' do
      expect(executor.running?).to be(true)
      executor.shutdown
      expect(executor.running?).to be(false)
    end

    it 'delivers work it had already accepted' do
      done = Queue.new
      executor.post(AsyncExecutorSpecHandler.new { |msg| done << msg }, :accepted)

      executor.shutdown

      expect(done.size).to eq(1)
      expect(done.pop).to eq(:accepted)
    end

    it 'is idempotent' do
      executor.shutdown
      expect { executor.shutdown }.not_to raise_error
    end
  end

  describe '#stats' do
    it 'reports the pool shape and backlog bound' do
      expect(executor.stats).to include(
        mode: :threads,
        size: 2,
        backlog_limit: described_class::DEFAULT_BACKLOG_LIMIT,
        in_flight: 0,
        queued: 0,
        refused: 0
      )
    end
  end
end
