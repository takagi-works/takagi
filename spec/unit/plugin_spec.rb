# frozen_string_literal: true

require 'takagi/plugin'
require 'takagi/base/plugin_management'

RSpec.describe Takagi::Plugin do
  before do
    Takagi::Plugin.registry.clear
  end
  module TestPlugin
    def self.metadata = { name: :test_plugin }
    def self.apply(app, opts = {}) # rubocop:disable Lint/UnusedMethodArgument
      if app.is_a?(Hash)
        app[:applied] = true
      elsif app.respond_to?(:instance_variable_set)
        app.instance_variable_set(:@config, { applied: true })
      else
        app[:applied] = true
      end
    end
  end

  module DepPlugin
    def self.metadata = { name: :dep_plugin }
    def self.apply(app, opts = {}); app[:dep] = true if app.is_a?(Hash); end
  end

  module MainPlugin
    def self.metadata = { name: :main_plugin, dependencies: [:dep_plugin] }
    def self.apply(app, opts = {}); app[:main] = opts; end
  end

  module SchemaPlugin
    def self.metadata = { name: :schema_plugin }
    def self.config_schema
      {
        host: { type: :string, required: true },
        port: { type: :integer, default: 5683, range: 1..65_535 },
        mode: { type: :string, enum: %w[prod dev] }
      }
    end

    def self.apply(app, opts = {}); app[:schema_opts] = opts; end
  end

  let(:app) { {} }

  it 'registers and enables a plugin' do
    info = described_class.register(TestPlugin)
    expect(info.name).to eq(:test_plugin)

    described_class.enable(:test_plugin, app: app)

    expect(app[:applied]).to be true
    expect(described_class.list.first[:enabled]).to be true
  end

  it 'enables plugins declared via Base::PluginManagement DSL' do
    klass = Class.new(Takagi::Base) do
      plugin TestPlugin
    end

    app = klass.new
    klass.enable_plugins!(app: app)

    expect(app.instance_variable_get(:@config)).to eq({ applied: true })
  end

  it 'enables dependencies automatically' do
    Takagi::Plugin.register(DepPlugin)
    Takagi::Plugin.register(MainPlugin)

    described_class.enable(:main_plugin, app: app, options: {})

    expect(app[:dep]).to be true
    expect(app[:main]).to eq({})
  end

  it 'validates config schema and fills defaults' do
    Takagi::Plugin.register(SchemaPlugin)

    described_class.enable(:schema_plugin, app: app, options: { host: 'localhost', mode: 'prod' })

    expect(app[:schema_opts]).to eq({ host: 'localhost', port: 5683, mode: 'prod' })
  end

  it 'raises when required config missing' do
    Takagi::Plugin.register(SchemaPlugin)

    expect { described_class.enable(:schema_plugin, app: app, options: {}) }.to raise_error(ArgumentError)
  end
end
