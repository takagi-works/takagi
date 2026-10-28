# frozen_string_literal: true

RSpec.describe Takagi::Observer::Watcher do
  let(:watcher) { described_class.new(interval: 0.05) }

  it "starts and stops the watcher" do
    thread = watcher.start
    expect(thread).to be_a(Thread)

    watcher.stop
    thread.join

    expect(thread.alive?).to be_falsey
  end

  it "notifies nothing from an interval: time alone produces no notification" do
    expect(Takagi::ObserveRegistry).not_to receive(:notify)

    thread = watcher.start
    sleep 0.2

    watcher.stop
    thread.join
  end
end