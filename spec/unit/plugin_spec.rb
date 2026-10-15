# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Takagi::Plugin do
  before do
    Takagi::Plugin.registry.clear
    Takagi::Router.reset!
  end

  let(:app_class) { Class.new(Takagi::Base) }

  describe 'unregister' do
    it 'removes plugin from registry' do
      mod = Module.new do
        def self.apply(*); end
      end
      info = Takagi::Plugin.register(mod)
      expect(Takagi::Plugin.registry.size).to eq(1)

      Takagi::Plugin.unregister(info.name)
      expect(Takagi::Plugin.registry.size).to eq(0)
    end
  end

  describe 'health' do
    it 'reports enabled, disabled, and unhealthy plugins' do
      ok = Module.new do
        def self.metadata
          { name: :ok_plugin }
        end

        def self.apply(*); end
      end
      bad = Module.new do
        def self.metadata
          { name: :bad_plugin }
        end

        def self.apply(*); end

        def self.healthy?
          false
        end
      end

      Takagi::Plugin.register(ok)
      Takagi::Plugin.register(bad)
      Takagi::Plugin.enable(:ok_plugin, app: app_class)
      Takagi::Plugin.enable(:bad_plugin, app: app_class)

      report = Takagi::Plugin.health.to_h { |h| [h[:name], h[:status]] }
      expect(report[:ok_plugin]).to eq(:ok)
      expect(report[:bad_plugin]).to eq(:unhealthy)
      expect(Takagi::Plugin.healthy?).to be(false)
    end
  end

  describe 'circular dependencies' do
    it 'raises when plugins depend on each other' do
      a = Module.new do
        def self.metadata
          { name: :cycle_a, dependencies: [{ name: :cycle_b }] }
        end

        def self.apply(*); end
      end
      b = Module.new do
        def self.metadata
          { name: :cycle_b, dependencies: [{ name: :cycle_a }] }
        end

        def self.apply(*); end
      end

      Takagi::Plugin.register(a)
      Takagi::Plugin.register(b)

      expect do
        Takagi::Plugin.enable(:cycle_a, app: app_class)
      end.to raise_error(ArgumentError, /Circular/)
    end
  end

  describe 'dependency version validation' do
    before do
      stub_const('Takagi::Plugins::Dep', Module.new do
        def self.metadata
          { name: :dep, version: '1.2.0' }
        end

        def self.apply(*); end
      end)
    end

    it 'enables dependencies with satisfied version' do
      dep = Takagi::Plugins::Dep
      Takagi::Plugin.register(dep)

      main = Module.new do
        def self.metadata
          { name: :main, dependencies: [{ name: :dep, version: '>=1.0.0' }] }
        end

        def self.apply(*); end
      end

      Takagi::Plugin.register(main)
      expect { Takagi::Plugin.enable(:main, app: app_class) }.not_to raise_error
    end

    it 'raises when dependency version is not satisfied' do
      dep = Takagi::Plugins::Dep
      Takagi::Plugin.register(dep)

      main = Module.new do
        def self.metadata
          { name: :main, dependencies: [{ name: :dep, version: '>=2.0.0' }] }
        end

        def self.apply(*); end
      end

      Takagi::Plugin.register(main)
      expect { Takagi::Plugin.enable(:main, app: app_class) }.to raise_error(/requires dep >=2.0.0/)
    end
  end

  describe 'route prefixing' do
    it 'prefixes routes declared by plugin' do
      plugin_mod = Module.new do
        def self.metadata
          { name: :prefixed, route_prefix: '/api' }
        end

        def self.apply(app, _opts = {})
          app.get '/hello' do
            respond message: 'hi'
          end
        end
      end

      Takagi::Plugin.register(plugin_mod)
      Takagi::Plugin.enable(:prefixed, app: app_class)

      expect(app_class.router.all_routes).to include('GET /api/hello')
    end
  end

  describe 'plugin order' do
    it 'enables plugins based on order' do
      calls = []

      first = Module.new do
        define_singleton_method(:metadata) { { name: :first } }
        define_singleton_method(:apply) { |_app, _opts = {}| calls << :first }
      end

      second = Module.new do
        define_singleton_method(:metadata) { { name: :second } }
        define_singleton_method(:apply) { |_app, _opts = {}| calls << :second }
      end

      stub_const('Takagi::Plugins::First', first)
      stub_const('Takagi::Plugins::Second', second)

      app = Class.new(Takagi::Base) do
        plugin :first, order: 10
        plugin :second, order: 1
      end

      app.enable_plugins!(app: app)
      expect(calls).to eq(%i[second first])
    end
  end

  describe 'config validation errors' do
    it 'mention plugin name' do
      mod = Module.new do
        def self.metadata
          { name: :confy }
        end

        def self.config_schema
          { foo: { type: :string, required: true } }
        end

        def self.apply(*); end
      end

      Takagi::Plugin.register(mod)
      expect { Takagi::Plugin.enable(:confy, app: app_class, options: { foo: 123 }) }
        .to raise_error(/confy/)
    end
  end
end
