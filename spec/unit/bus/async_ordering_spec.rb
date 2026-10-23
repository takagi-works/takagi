# frozen_string_literal: true

require 'spec_helper'
require 'timeout'

# Row 3 of .omo/plans/local-bus.md: a subscriber that asks for `async: true` is
# handed to the executor, which keeps ITS messages in publication order and never
# runs it concurrently with itself.
#
# The failure scenario the row asks for is produced from this file rather than
# described: `TAKAGI_LEGACY_EXECUTOR=1 rspec spec/unit/bus/async_ordering_spec.rb`
# installs `LegacyPoolDrainer` instead of the executor, and the ordering example
# then fails naming in-flight count 2.
#
# Reproduces the pre-row-3 executor byte-for-behaviour: one shared queue, N
# drainers, no per-handler affinity, as it stood in
# lib/takagi/bus/async_executor.rb md5 7bdb9fccd1322952df15dde65099a346.
class LegacyPoolDrainer
  def initialize(size:)
    @size = size.positive? ? size : 1
    @queue = Queue.new
    @threads = []
    @size.times do |index|
      @threads << Thread.new do
        Thread.current.name = "EventBus-ThreadExecutor-#{index}"
        loop do
          job = @queue.pop
          break if job.nil?

          job.first.call(job.last)
        end
      end
    end
  end

  def post(handler, message)
    @queue << [handler, message]
  end

  def register_handler(_handler); end

  def unregister_handler(_handler); end

  def shutdown
    @size.times { @queue << nil }
    @threads.each(&:join)
    @threads.clear
  end

  def running?
    true
  end

  def stats
    { mode: :legacy }
  end
end

class AsyncOrderingRecorder
  attr_reader :started, :release, :finished

  def initialize
    @started = Queue.new
    @release = Queue.new
    @finished = Queue.new
    @samples = []
    @thread_names = []
    @in_flight = 0
    @max_in_flight = 0
    @mutex = Mutex.new
  end

  def call(message)
    seq = message.body[:seq]
    @mutex.synchronize do
      @in_flight += 1
      @max_in_flight = @in_flight if @in_flight > @max_in_flight
      @thread_names << Thread.current.name
    end
    @started << seq
    @release.pop if seq == 1
    @mutex.synchronize do
      @samples << seq
      @in_flight -= 1
    end
    @finished << seq
  end

  # Only the first delivery blocks, so one token frees any delivery a failed
  # example left parked on `release`.
  def release!
    @release << :go
  end

  def samples
    @mutex.synchronize { @samples.dup }
  end

  def max_in_flight
    @mutex.synchronize { @max_in_flight }
  end

  def thread_names
    @mutex.synchronize { @thread_names.dup }
  end
end

RSpec.describe 'Takagi::Bus asynchronous subscriber ordering' do
  let(:bus) { Takagi::Bus.new }
  let(:recorder) { AsyncOrderingRecorder.new }

  after do
    recorder.release!
    bus.shutdown
  end

  def executor_class
    ENV['TAKAGI_LEGACY_EXECUTOR'] ? LegacyPoolDrainer : Takagi::Bus::AsyncExecutor::ThreadExecutor
  end

  def install_executor(bus)
    bus.instance_variable_set(:@executor, executor_class.new(size: 8))
  end

  def publish(bus, address, seq)
    Timeout.timeout(2) { bus.publish(address, { seq: seq }) }
  rescue Timeout::Error
    raise "publish #{seq} to #{address} did not return within 2s: delivery is still running on the publishing thread"
  end

  def next_start_within(recorder, seconds)
    Timeout.timeout(seconds) { recorder.started.pop }
  rescue Timeout::Error
    nil
  end

  it "keeps one async subscriber's messages in publication order and never concurrent with itself" do
    bus.consumer('ordered.async', async: true) { |msg| recorder.call(msg) }
    install_executor(bus)

    publish(bus, 'ordered.async', 1)
    publish(bus, 'ordered.async', 2)

    expect(next_start_within(recorder, 5)).to eq(1), 'the first delivery never started'
    second_start = next_start_within(recorder, 0.4)
    expect(second_start).to be_nil, "a second delivery started while the first was in flight (in-flight #{recorder.max_in_flight})"
    expect(recorder.max_in_flight).to eq(1), 'the subscriber ran concurrently with itself'

    recorder.release << :go

    expect(Timeout.timeout(5) { recorder.finished.pop }).to eq(1)
    expect(next_start_within(recorder, 5)).to eq(2), 'the message published second never ran after the first'
    expect(Timeout.timeout(5) { recorder.finished.pop }).to eq(2)
    expect(recorder.samples).to eq([1, 2])
    expect(recorder.max_in_flight).to eq(1)
    expect(recorder.thread_names).to all(start_with('EventBus-ThreadExecutor-'))
  end

  it 'keeps three messages to one async subscriber in publication order' do
    received = Queue.new
    bus.consumer('ordered.series', async: true) { |msg| received << msg.body[:seq] }
    install_executor(bus)

    (1..3).each { |seq| publish(bus, 'ordered.series', seq) }

    expect(Timeout.timeout(5) { received.pop }).to eq(1)
    expect(Timeout.timeout(5) { received.pop }).to eq(2)
    expect(Timeout.timeout(5) { received.pop }).to eq(3)
  end

  it 'leaves a synchronous subscriber on the publishing thread, in order' do
    threads = []
    samples = []
    bus.consumer('ordered.sync') do |msg|
      threads << Thread.current
      samples << msg.body[:seq]
    end

    (1..3).each { |seq| publish(bus, 'ordered.sync', seq) }

    expect(samples).to eq([1, 2, 3])
    expect(threads).to eq([Thread.current] * 3)
    expect(bus.executor).to be_nil
  end

  it 'builds no executor until a subscriber asks for async delivery' do
    expect(bus.executor).to be_nil

    bus.consumer('lazy.sync') { |_msg| :ok }
    publish(bus, 'lazy.sync', 1)
    expect(bus.executor).to be_nil

    bus.consumer('lazy.async', async: true) { |_msg| :ok }
    publish(bus, 'lazy.async', 1)
    expect(bus.executor).to be_a(Takagi::Bus::AsyncExecutor::ThreadExecutor)
  end
end
