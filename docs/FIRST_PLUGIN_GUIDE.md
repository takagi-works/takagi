# First Plugin Guide

Build a Takagi plugin that adds routes, content-formats, and even transports, without touching core code.

## Plugin contract (what you implement)
- Module (ideally `Takagi::Plugins::<Name>`) with `.apply(app, opts = {})`.
- Optional lifecycle: `.before_apply(app, opts)`, `.after_apply(app, opts)`, `.before_unload(app)`, `.shutdown(app)`.
- Optional metadata via `.metadata` hash: `{ name:, description:, requires:, dependencies: [] }`.
- Optional config schema via `.config_schema` hash: keys → rules (`:type`, `:required`, `:default`, `:enum`, `:range`, `:validate` proc).
- Optional route prefix isolation via `metadata[:route_prefix]` to auto-prefix routes registered by the plugin.
- Enable via `plugin :name, opts` in your app + `enable_plugins!`, or via config (`Takagi.config.plugins.enabled`). Auto-discovery will pick up `Takagi::Plugins::*` and gems named `takagi-plugin-*`.
  - You can order plugins with `plugin :name, order: 10` (lower runs first).

## Minimal skeleton
```ruby
# lib/takagi/plugins/hello.rb
module Takagi
  module Plugins
    module Hello
      def self.metadata
        { name: :hello, description: 'Adds /hello endpoint' }
      end

      def self.config_schema
        { greeting: { type: :string, default: 'Hello' } }
      end

      # Optional: isolate routes under /hello
      def self.metadata
        { name: :hello, route_prefix: '/hello' }
      end

      def self.apply(app, opts = {})
        greeting = opts[:greeting] || 'Hello'
        app.get '/hello' do
          respond message: "#{greeting}, CoAP!"
        end
      end
    end
  end
end
```

Enable it:
```ruby
class MyAPI < Takagi::Base
  plugin :hello, greeting: 'Ahoy'
end
MyAPI.enable_plugins!
```
Or via config: add `{ name: :hello, options: { greeting: 'Hi' } }` to `Takagi.config.plugins.enabled`.

## Add a new content-format + serializer
```ruby
module Takagi
  module Plugins
    module SenmlCbor
      def self.metadata
        { name: :senml_cbor, description: 'SenML CBOR support', version: '1.0.0' }
      end

      def self.apply(_app, _opts = {})
        serializer = Class.new(Takagi::Serialization::Base) do
          def encode(data) CBOR.encode(data) end
          def decode(bytes) CBOR.decode(bytes) end
          def content_type; 'application/senml+cbor'; end
          def content_format_code; 112; end # example code
        end

        Takagi::Serialization::Registry.register(serializer.new.content_format_code, serializer)
        Takagi::CoAP::Registries::ContentFormat.register(serializer.new.content_format_code, serializer.new.content_type, :senml_cbor)
      end
    end
  end
end
```
Use it in routes by setting `ct:` metadata or `respond(payload, force: 112)`; `respond` negotiates with `Accept` and returns `4.06/4.15` when unsupported.

## Add a new protocol/transport
```ruby
module Takagi
  module Plugins
    module Quic
      def self.metadata
        { name: :quic, description: 'CoAP over QUIC' }
      end

      def self.apply(app, opts = {})
        Takagi::Server::Registry.register(:quic, Takagi::Server::Quic, rfc: 'RFC xxxx')
        Takagi::Network::Registry.register(:quic, Takagi::Network::Quic)
        # Optionally auto-enable:
        app.run!(protocols: (opts[:protocols] || [:udp, :tcp, :quic]))
      end
    end
  end
end
```
Implement `Takagi::Server::Quic` and `Takagi::Network::Quic` similar to UDP/TCP classes.

## Plugin-specific controllers/routes
Add routes directly in `.apply`:
```ruby
def self.apply(app, _opts = {})
  app.get '/plugin/info', metadata: { ct: Takagi::CoAP::Registries::ContentFormat::JSON } do
    respond name: 'my_plugin', version: '1.0.0'
  end
end
```
If you want a dedicated controller class, subclass `Takagi::Base` or `Takagi::Controller` and register its routes inside `.apply`.

## Register new CoAP codes/options (if needed)
- Methods: `Takagi::CoAP::Registries::Method.register(7, 'CUSTOM', :custom)`
- Responses: `Takagi::CoAP::Registries::Response.register(231, '7.07 Custom', :custom)` (helper methods are generated).
- Options: `Takagi::CoAP::Registries::Option.register(65000, 'Plugin-Option', :plugin_option)`

## Hooks and events
Hooks emitted during plugin lifecycle: `:plugin_registered`, `:plugin_enabling`, `:plugin_enabled`, `:plugin_disabling`, `:plugin_disabled`, `:plugin_error` (see `docs/HOOKS.md`). Subscribe if you need side effects/logging. You can also publish EventBus events under `plugin.*` if needed.

### Lifecycle hooks (and when to use them)
- `:plugin_registered` — after a plugin module is registered. Use to log or audit availability.
- `:plugin_enabling` — before `.apply` runs. Use to perform pre-flight checks or metrics.
- `:plugin_enabled` — after `.apply` completes. Use to announce availability (e.g., publish `plugin.started`).
- `:plugin_disabling` — before shutdown/unload. Use to stop background work or flush buffers.
- `:plugin_disabled` — after shutdown/unload. Use to log or emit “stopped” events.
- `:plugin_error` — when any lifecycle step raises. Use to alert/rollback.

Subscribe via `Takagi::Hooks.on(:event_name) { |payload| ... }` (see `docs/HOOKS.md`).

### Other useful hooks (see `docs/HOOKS.md` for payloads)
- Router/routes: `:router_route_added` — track dynamic route registration (metrics/debug).
- Middleware: `:middleware_before_call`, `:middleware_after_call` — wrap/measure middleware execution.
- Response build: `:before_response_build`, `:after_response_build` — observe how results become responses.
- Server lifecycle: `:server_starting`, `:server_stopped` — start/stop transport-adjacent resources.
- Worker lifecycle: `:controller_workers_started`, `:controller_workers_stopped` — manage thread-bound resources.
- Observe: `:observe_subscribed`, `:observe_unsubscribed`, `:observe_notify_start`, `:observe_notify_end` — instrument CoAP Observe flows.
- CoAP registries: `:coap_registry_registered`, `:coap_registry_cleared` — react to new methods/options/content-formats.

### Hook payloads and quick examples
Subscribe with `Takagi::Hooks.on(:hook) { |p| ... }`, emit with `Takagi::Hooks.emit(:hook, payload)`.

- `:coap_registry_registered` — keys: `registry`, `value`, `name`, `symbol`, `rfc`.  
  Example: `Takagi::Hooks.on(:coap_registry_registered) { |p| Takagi.logger.info("Registry #{p[:registry]} added #{p[:name]} (#{p[:value]})") }`
- `:coap_registry_cleared` — keys: `registry`.  
  Example: `Takagi::Hooks.on(:coap_registry_cleared) { |p| Takagi.logger.warn("Registry cleared: #{p[:registry]}") }`
- `:router_route_added` — keys: `method`, `path`, `entry`.  
  Example: `Takagi::Hooks.on(:router_route_added) { |p| Takagi.logger.info("Route #{p[:method]} #{p[:path]} added") }`
- `:middleware_before_call` — keys: `request`.  
  Example: `Takagi::Hooks.on(:middleware_before_call) { |p| metrics.increment(:mw_in) }`
- `:middleware_after_call` — keys: `request`, `response`.  
  Example: `Takagi::Hooks.on(:middleware_after_call) { |p| metrics.timing(:mw_latency, Time.now - p[:request].started_at) if p[:request].respond_to?(:started_at) }`
- `:before_response_build` — keys: `inbound`, `result`.  
  Example: `Takagi::Hooks.on(:before_response_build) { |p| Takagi.logger.debug("Building response from #{p[:result].class}") }`
- `:after_response_build` — keys: `inbound`, `response`, `result`.  
  Example: `Takagi::Hooks.on(:after_response_build) { |p| metrics.increment(:responses) }`
- `:server_starting` — keys: `protocol`, `port`.  
  Example: `Takagi::Hooks.on(:server_starting) { |p| Takagi.logger.info("Starting #{p[:protocol]} on #{p[:port]}") }`
- `:server_stopped` — keys: `protocol`, `port`.  
  Example: `Takagi::Hooks.on(:server_stopped) { |p| Takagi.logger.info("Stopped #{p[:protocol]} on #{p[:port]}") }`
- `:controller_workers_started` — keys: `controller`, `name`, `threads`.  
  Example: `Takagi::Hooks.on(:controller_workers_started) { |p| metrics.gauge(:worker_threads, p[:threads]) }`
- `:controller_workers_stopped` — keys: `controller`.  
  Example: `Takagi::Hooks.on(:controller_workers_stopped) { |p| Takagi.logger.info("Workers stopped for #{p[:controller]}") }`
- `:observe_subscribed` — keys: `path`, `subscription`.  
  Example: `Takagi::Hooks.on(:observe_subscribed) { |p| metrics.increment(:observe_subscriptions) }`
- `:observe_unsubscribed` — keys: `path`, `token`.  
  Example: `Takagi::Hooks.on(:observe_unsubscribed) { |p| metrics.increment(:observe_unsubscriptions) }`
- `:observe_notify_start` — keys: `path`, `subscribers`, `value`.  
  Example: `Takagi::Hooks.on(:observe_notify_start) { |p| metrics.gauge(:observers, p[:subscribers].size) }`
- `:observe_notify_end` — keys: `path`, `delivered`, `value`.  
  Example: `Takagi::Hooks.on(:observe_notify_end) { |p| metrics.increment(:observe_notifications, p[:delivered]) }`
- `:plugin_registered` — keys: `name`, `metadata`.  
  Example: `Takagi::Hooks.on(:plugin_registered) { |p| Takagi.logger.info("Plugin registered: #{p[:name]}") }`
- `:plugin_enabling` — keys: `name`, `metadata`, `options`.  
  Example: `Takagi::Hooks.on(:plugin_enabling) { |p| audit("enable #{p[:name]}", p[:options]) }`
- `:plugin_enabled` — keys: `name`, `metadata`.  
  Example: `Takagi::Hooks.on(:plugin_enabled) { |p| EventBus.publish('plugin.started', p) if defined?(EventBus) }`
- `:plugin_disabling` — keys: `name`, `metadata`.  
  Example: `Takagi::Hooks.on(:plugin_disabling) { |p| audit("disable #{p[:name]}") }`
- `:plugin_disabled` — keys: `name`, `metadata`.  
  Example: `Takagi::Hooks.on(:plugin_disabled) { |p| Takagi.logger.info("Plugin disabled: #{p[:name]}") }`
- `:plugin_error` — keys: `name`, `metadata`, `error`.  
  Example: `Takagi::Hooks.on(:plugin_error) { |p| Takagi.logger.error("Plugin error #{p[:name]}: #{p[:error]}") }`

### Hook call order (lifecycle sketch)
```
Plugin enable:
  plugin_registered (when module is registered)
  plugin_enabling
    before_apply (optional, plugin hook)
    apply        (plugin logic runs)
    after_apply  (optional, plugin hook)
  plugin_enabled
  plugin_error (on any failure above)

Plugin disable:
  plugin_disabling
    before_unload (optional)
    shutdown      (optional)
  plugin_disabled
  plugin_error (on failure)

Server/workers:
  server_starting -> controller_workers_started -> ...runtime... -> controller_workers_stopped -> server_stopped

Request/response:
  middleware_before_call -> ...handler... -> before_response_build -> after_response_build -> middleware_after_call

Routes/registries:
  router_route_added (when route registered)
  coap_registry_registered (when registry extended)
  coap_registry_cleared (mostly in tests/reset)

Observe:
  observe_subscribed / observe_unsubscribed
  observe_notify_start -> observe_notify_end
```

## Checklist
1) Create `Takagi::Plugins::YourPlugin` with `.apply`.
2) (Optional) Add serializers/content-formats; register in both `Serialization::Registry` and `CoAP::Registries::ContentFormat`.
3) (Optional) Add transport: register server + network transport.
4) Add routes (or a controller) using `respond`, set `ct` metadata so discovery and negotiation stay aligned; use `route_prefix` if you want isolation.
5) Declare metadata/config schema; handle dependencies/`requires`/dependency versions.
6) Enable via `plugin :your_plugin, options, order: X` and call `enable_plugins!` (or rely on auto-discovery/config).
