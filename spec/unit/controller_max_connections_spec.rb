# frozen_string_literal: true

# Row 21 of .omo/plans/tcp-multi-worker.md: a controller-level `max_connections` is not a
# concurrency setting. A controller holds no accepted connections, so nothing ever consumed the
# key - before this row `set :max_connections, 5` was accepted, allocated and dropped in silence
# (the verifier measured no consumer anywhere in `lib/`) - and the CONTROLLER boundary now refuses
# it, naming the key, the controller and the reason. It is deliberately not a general per-key
# whitelist: `set :processes` and `set :threads` stay accepted, because both ARE consumed (the
# profile/fallback input and the controller's own pool, as row 9 verified).
RSpec.describe 'a controller-level max_connections (plan row 21)' do
  def controller_named(name)
    klass = Class.new(Takagi::Controller)
    stub_const(name, klass)
    klass
  end

  it 'refuses set :max_connections, naming the key, the controller and the reason (PROOF)' do
    controller = controller_named('MaxConnectionsProbeController')

    expect { controller.configure { set :max_connections, 5 } }
      .to raise_error(ArgumentError) do |error|
        expect(error.message).to include('set :max_connections, 5')
        expect(error.message).to include('MaxConnectionsProbeController')
        expect(error.message).to include('holds no accepted connections')
        expect(error.message).to include('protocol_settings: { tcp: { max_connections: <N> } }')
      end
  end

  it 'refuses the key before it is written onto the controller (PROOF)' do
    controller = controller_named('MaxConnectionsUnwrittenController')

    expect { controller.configure { set :max_connections, 5 } }.to raise_error(ArgumentError)

    expect(controller.config).not_to have_key(:max_connections)
  end

  it 'still accepts a controller threads count (GUARD, row 9)' do
    controller = controller_named('MaxConnectionsThreadsController')

    controller.configure { set :threads, 8 }

    expect(controller.config[:threads]).to eq(8)
    expect(controller.thread_count).to eq(8)
  end

  it 'still accepts a controller processes count, its profile fallback input (GUARD, row 9)' do
    controller = controller_named('MaxConnectionsProcessesController')

    controller.configure { set :processes, 4 }

    expect(controller.config[:processes]).to eq(4)
    expect(controller.process_count).to eq(4)
  end
end
