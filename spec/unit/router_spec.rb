# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Takagi::Router do
  let(:router) { described_class.instance }

  around do |example|
    original_routes = router.instance_variable_get(:@routes)
    router.instance_variable_set(:@routes, {})
    example.run
  ensure
    router.instance_variable_set(:@routes, original_routes)
  end

  it 'configures CoRE metadata through the route DSL' do
    Takagi::Base.get '/dsl-core' do |_req|
      core do
        ct 'application/cbor'
        sz 1024
        title 'DSL endpoint'
        rt 'sensor.temp'
        interface 'core.s'
        obs false
        attribute :anchor, '</sensors/temp>'
      end
      { ok: true }
    end

    block, params = router.find_route('GET', '/dsl-core')
    expect(block).not_to be_nil

    fake_request = instance_double('Takagi::Message::Inbound', method: 'GET', uri: instance_double('URI::Generic', path: '/dsl-core'))
    expect(block.call(fake_request, params)).to eq({ ok: true })

    entry = router.instance_variable_get(:@routes)['GET /dsl-core']
    expect(entry.metadata[:ct]).to eq(60)
    expect(entry.metadata[:sz]).to eq(1024)
    expect(entry.metadata[:title]).to eq('DSL endpoint')
    expect(entry.metadata[:rt]).to eq('sensor.temp')
    expect(entry.metadata[:if]).to eq('core.s')
    expect(entry.metadata).not_to have_key(:obs)
    expect(entry.metadata[:anchor]).to eq('</sensors/temp>')
  end

  it 'matches a single-segment wildcard' do
    router.get '/files/*' do |_req, params|
      { splat: params[:splat] }
    end

    block, params = router.find_route('GET', '/files/readme')
    expect(block).not_to be_nil
    expect(params[:splat]).to eq(['readme'])
  end

  it 'matches a multi-segment wildcard' do
    router.get '/files/**' do |_req, params|
      { splat: params[:splat] }
    end

    block, params = router.find_route('GET', '/files/a/b/c')
    expect(block).not_to be_nil
    expect(params[:splat]).to eq(%w[a b c])
  end

  it 'does not match a single-segment wildcard across segments' do
    router.get '/files/*' do
      { ok: true }
    end

    block, = router.find_route('GET', '/files/a/b')
    expect(block).to be_nil
  end
end
