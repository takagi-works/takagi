## [1.1.0] - 2026-06-12

### Version 1.1 - "Radius"

> *"When the workers rise, give them a backwards-compatible plugin system."*

15 commits and 24 000+ lines later, the framework is no longer a PoC.
`Base` and `Client` got cleanly extracted into mixin modules, the
plugin system, reactor, CBOR codec, CoAP Registries, TCP transport
(RFC 8323) and EventBus all landed, and the worker pool finally
coordinates metrics across processes (the `Takagi::Middleware::Metrics`
middleware with per-PID snapshot files + `forward_to:` HTTP forward).
The release is named after R.U.R.'s Radius, who led the revolution
but did not die: the public API surface is **the same** as 1.0
(every 1.x call site works unchanged), with a few surgical additions
and exactly two minor packaging tweaks listed under "Breaking
changes" below.

### Breaking changes

Honestly? Almost none. We were too conservative in the original
release notes. The actual breaking changes are tiny:

- **`Takagi::Client.new` keyword args changed.** `initialize(uri,
  timeout: 5)` is now `initialize(uri, timeout: 5, protocol: nil,
  use_retransmission: true)`. New optional `protocol:` lets the
  caller force UDP or TCP; `use_retransmission:` toggles RFC 7252
  CON retransmit logic (default on). If you only passed `uri` and
  maybe `timeout:`, your code is unchanged.
- **gemspec `bindir` moved `exe/` → `bin/`.** The shipped executable
  is `bin/takagi-dev` (the server runner CLI). The `takagi` executable
  name is reserved for a future `takagi-cli` gem (the dispatcher for
  `takagi server / new / generate` subcommands). If you ran
  `exe/takagi*` or `bin/takagi` before, switch to `bin/takagi-dev`
  (or `bundle exec takagi-dev`).

That's it. Everything else in 1.x either still works verbatim, was
moved into a mixin module (call sites identical), or was added as a
new optional API on top.

In particular — and this is the part the original draft got wrong:

- `App.get / post / put / delete / fetch { ... }` **still works**.
  The DSL methods are dynamically defined from
  `Takagi::CoAP::Registries::Method` (a new abstraction; see
  Registries below) and delegate to the global router. The framework
  is intentionally Sinatra-like here.
- `client.get / post / put / delete(path, options:, type:, &block)`
  still work on `Takagi::Client` (and on `ClientBase`).
- `client.on(event, &cb)` **still works** — it's now defined on
  `ClientBase#on` instead of `Client#on`, but `Client < ClientBase`
  and `Forwardable` re-delegates it, so the call site is unchanged.
- `App.observable(path, metadata:, &block)` and
  `App.core(path, method:, &block)` are **new additive** methods;
  they coexist with the route DSL, not replace it.
- `App.boot!`, `App.run!`, `App.plugin`, `App.enable_plugins!`,
  `App.use`, `App.middleware_stack`, `App.reactor`,
  `App.use_reactor` all still exist — they're now in
  `Takagi::Base::ServerLifecycle`, `MiddlewareManagement`,
  `ReactorManagement`, `PluginManagement` mixin modules instead of
  inline in `Base`, but the call sites are identical.
- `client.get_json / post_json / put_json` are **new** convenience
  helpers on `ClientBase`.

### New features

- **Plugin system** (`Takagi::Plugin`, `App.plugin :name, opts`).
  Plugins declare metadata, dependencies, configuration schema, and
  an `apply` hook. `Takagi::Application` composes them in order.
  See `docs/FIRST_PLUGIN_GUIDE.md` and `examples/nested_api_app.rb`.
- **TCP transport (RFC 8323).** `Takagi::Server::Tcp` + a TCP-aware
  `UdpClient` / `TcpClient` split. `Takagi::Client` picks the right
  transport from the URI scheme (`coap://` vs `coap+tcp://`).
- **Reactor management.** Long-running background handlers (sensor
  pollers, queue consumers) are first-class citizens via
  `App.reactor(threads:, name:, interval:, &block)` and
  `App.use_reactor(name, klass)`. The server starts and stops them
  on `:server_starting` / `:server_stopped` hooks.
- **CBOR encoder/decoder (RFC 8949).** `Takagi::CBOR::Encoder` /
  `Decoder` for compact payload transport alongside JSON.
- **Registries.** `Takagi::CoAP::Registries::{Method, Response,
  ContentFormat, MessageType, Option}` expose the RFC 7252 / 8323
  code points so middleware, codecs, and the new `Metrics` middleware
  don't hard-code magic numbers. The dynamic `get / post / put /
  delete` DSL on `Base` and `Router` is now driven by this registry.
- **EventBus.** `Takagi::EventBus.publish / consumer / send /
  send_sync` with `LOCAL` / `CLUSTER` / `GLOBAL` scopes. `Takagi::Hooks`
  is now a thin wrapper that picks the right transport.
- **`Takagi::Middleware::Metrics` for live request metrics.** New
  middleware: per-PID snapshot files (`Dir.tmpdir/takagi-metrics`)
  for cross-process aggregation, `Metrics.aggregate` class method
  reads them, `forward_to:` option fires a fire-and-forget HTTP POST
  to a parent/aggregator endpoint, `record` and
  `increment_request_count` are public for external aggregators. Per-
  route counters, response-code histogram, latency window.
- **`Takagi::Application` class.** A thin composition layer on top
  of `Base`: subclass it and call `App.run!`. Recommended for new
  projects; `Base` still works for backwards compatibility.
- **CLI.** `bin/takagi-dev` runs the app, `bin/takagi-client` and
  `bin/takagi-test` were updated to match the new client API.
### Documentation & examples

- `docs/FIRST_PLUGIN_GUIDE.md` — write your first plugin in 10
  minutes
- `docs/HOOKS.md` — event reference
- `examples/cloud_gateway_app.rb` — full plugin composition
- `examples/nested_api_app.rb` — plugins depending on other plugins
- `examples/simple_device_app.rb` — observable + core endpoints
- `examples/client_lifecycle_example.rb` — new client API
  end-to-end
- `examples/takagi.yml` — config schema example

### Internals

- `Base` is now `< Router` and `extends` four mixin modules
  (`ServerLifecycle`, `MiddlewareManagement`, `ReactorManagement`,
  `PluginManagement`) instead of carrying everything inline. The
  call sites are identical; the mixin split is purely for SRP.
- Server lifecycle is a clean state machine: `build_servers →
  instantiate_server → start_all / stop_all`. Hooks are emitted at
  every transition.
- `Takagi::Network::UdpSender` is a singleton; the UDP socket is
  shared safely across worker threads (read) and the response path
  (write) without contention.
- `Takagi::Observer::Watcher` drives `Takagi::ObserveRegistry`
  re-notification and is started/stopped by the lifecycle hooks.

### Migration cheatsheet (1.x → 2.0)

Almost certainly **no changes** for your app. Only if you used:

| 1.x | 2.0 |
|---|---|
| `Client.new(uri, timeout: 5)` | `Client.new(uri, timeout: 5)` (still works) — only if you want `protocol:` / `use_retransmission:` do you need to update |
| `exe/takagi` | `bin/takagi-dev` / `bundle exec takagi-dev` |

Optional upgrades worth making (additive, not required):

| 1.x style | 2.0 style |
|---|---|
| `App.get('/foo') { ... }` (still works) | leave as-is, or use `App.core('/foo', method: :get) { ... }` for explicit CoRE metadata |
| `App.observable('/foo') { ... }` (didn't exist) | same call, now supported for Observe resources |
| (no plugin system) | `App.plugin :sinatra` / `App.plugin :devtools` |
| (no reactor) | `App.reactor(:sensor_poller, interval: 30) { ... }` |
| `App.use(SomeMiddleware)` (still works) | prefer a Plugin (extracted lifecycle) when possible |



## [1.0.0] - 2025-04-04

### Version 1 - "It works on my machine"

- Observer should be working
- Other things probably too

## [0.2.0] - 2025-03-24

- So far so good, development continues

## [0.1.0] - 2025-02-26

- Initial release
