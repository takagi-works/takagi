# frozen_string_literal: true

# `blockwise do ... end`: a route declares its own block-wise settings beside `core do ... end`,
# in the same readable style, and the BlockWise middleware overlays them onto the global
# configuration for that route alone.
#
# The declaration is captured at BOOT, the same way `core` is: MetadataExtractor runs the handler
# once when the route is registered and the AttributeSet persists the staged values into the route
# metadata under :block_wise. RouteContext's per-request AttributeSet is built from a copy, so the
# boot pass is the one that matters - and it is what lets a middleware that runs BEFORE the handler
# read the route's own declaration.
RSpec.describe 'the per-route `blockwise` declaration' do
  let(:router) { Takagi::Router.new }

  before do
    router.get('/metrics') do
      core do
        title 'Environment Metrics'
        rt %w[sensor.metrics sensor.temp]
        interface 'core.s'
        sz 256
      end

      blockwise do
        szx 4
        max_bytes 8192
        ttl 10
        max_assemblies 8
      end

      { temp: 21.4, humidity: 0.48 }
    end

    router.get('/plain') { { ok: true } }
  end

  def metadata_for(path)
    router.find_entry('GET', path).metadata
  end

  it 'captures the declared settings onto the route (PROOF)' do
    expect(metadata_for('/metrics')[:block_wise]).to eq(
      enabled: true, szx: 4, max_assembled_bytes: 8192, assembly_ttl: 10, max_concurrent_assemblies: 8
    )
  end

  # Declaring the block IS the opt-in, so a route can turn block-wise on against a globally disabled
  # feature. The implied value is merged UNDER whatever the block sets, which is what keeps this
  # example passing - apply it after the setters instead and it captures enabled: true.
  it 'lets the block turn the feature off over its own implied opt-in (PROOF)' do
    declaring = Takagi::Router.new
    declaring.get('/off') do
      blockwise do
        enabled false
      end

      { ok: true }
    end

    expect(declaring.find_entry('GET', '/off').metadata[:block_wise]).to eq(enabled: false)
  end

  # A route that declares nothing must stay exactly as it was: no settings at all, so the global
  # `block_wise.enabled` alone governs it.
  it 'declares nothing for a route that has no block (GUARD)' do
    expect(metadata_for('/plain')[:block_wise]).to be_nil
  end

  it 'leaves the CoRE `sz` size estimate exactly where the core block put it (GUARD)' do
    expect(metadata_for('/metrics')[:sz]).to eq(256)
  end

  # `sz` is RFC 6690's estimate for discovery and the block-wise knobs are behaviour, so the two
  # never share a key. This is also the invariant that keeps a route's internal settings out of the
  # document every client can read: link_attributes_for emits only the known CoRE attributes.
  it 'never leaks into the CoRE Link Format document (GUARD)' do
    declared = Takagi::Router.new
    declared.get('/metrics') do
      core do
        title 'Environment Metrics'
        rt %w[sensor.metrics sensor.temp]
        interface 'core.s'
        sz 256
      end

      blockwise do
        szx 4
        max_bytes 8192
      end

      { temp: 21.4 }
    end

    undeclared = Takagi::Router.new
    undeclared.get('/metrics') do
      core do
        title 'Environment Metrics'
        rt %w[sensor.metrics sensor.temp]
        interface 'core.s'
        sz 256
      end

      { temp: 21.4 }
    end

    with_block = Takagi::Discovery::CoreLinkFormat.generate(router: declared)
    without_block = Takagi::Discovery::CoreLinkFormat.generate(router: undeclared)

    expect(with_block).to eq(without_block)
    expect(with_block).not_to match(/block/i)
  end
end