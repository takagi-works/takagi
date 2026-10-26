# frozen_string_literal: true

RSpec.describe Takagi::Application do
  after do
    Object.send(:remove_const, :TestApp) if defined?(TestApp)
    Object.send(:remove_const, :TelemetryController) if defined?(TelemetryController)
    Object.send(:remove_const, :ConfigController) if defined?(ConfigController)
  end

  describe '.router' do
    it 'creates a composite router' do
      class TestApp < Takagi::Application; end

      expect(TestApp.router).to be_a(Takagi::CompositeRouter)
    end
  end

  describe '.config' do
    it 'creates a configuration hash' do
      class TestApp < Takagi::Application; end

      expect(TestApp.config).to be_a(Hash)
      expect(TestApp.config).to include(:controllers, :auto_load_patterns)
    end
  end

  describe '.configure' do
    it 'registers controllers via load_controllers' do
      class TelemetryController < Takagi::Controller
        configure do
          mount '/telemetry'
        end
      end

      class ConfigController < Takagi::Controller
        configure do
          mount '/config'
        end
      end

      class TestApp < Takagi::Application
        configure do
          load_controllers TelemetryController, ConfigController
        end
      end

      expect(TestApp.controllers).to include(TelemetryController, ConfigController)
    end

    it 'registers auto-load patterns' do
      class TestApp < Takagi::Application
        configure do
          auto_load 'app/controllers/**/*_controller.rb'
        end
      end

      expect(TestApp.config[:auto_load_patterns]).to include('app/controllers/**/*_controller.rb')
    end
  end

  describe '.load_controllers!' do
    it 'mounts all registered controllers' do
      class TelemetryController < Takagi::Controller
        configure do
          mount '/telemetry'
        end

        get '/data' do; end
      end

      class TestApp < Takagi::Application
        configure do
          load_controllers TelemetryController
        end
      end

      TestApp.load_controllers!

      # Three mounts: the discovery controller, the application root (app-level and plugin routes),
      # and the loaded controller.
      expect(TestApp.router.mounted_controllers.map(&:mount_path)).to include('/.well-known', '/', '/telemetry')
      expect(TestApp.router.all_routes).to include('GET /telemetry/data')
      expect(TestApp.router.all_routes).to include('GET /.well-known/core')  # Discovery endpoint
    end
  end

  describe 'integration' do
    it 'routes requests through mounted controllers' do
      class TelemetryController < Takagi::Controller
        configure do
          mount '/telemetry'
        end

        post '/data' do
          { received: true }
        end
      end

      class ConfigController < Takagi::Controller
        configure do
          mount '/config'
        end

        get '/settings' do
          { settings: {} }
        end
      end

      class TestApp < Takagi::Application
        configure do
          load_controllers TelemetryController, ConfigController
        end
      end

      TestApp.load_controllers!

      # Test routing through composite router
      handler1, = TestApp.router.find_route('POST', '/telemetry/data')
      handler2, = TestApp.router.find_route('GET', '/config/settings')

      expect(handler1).not_to be_nil
      expect(handler2).not_to be_nil
    end
  end
end
