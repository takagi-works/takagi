# Takagi – Lightweight CoAP Framework for Ruby

[![Gem Version](https://badge.fury.io/rb/takagi.svg)](https://rubygems.org/gems/takagi)
[![Build Status](https://github.com/domitea/takagi/actions/workflows/main.yml/badge.svg)](https://github.com/domitea/takagi/actions)

## About Takagi

**Takagi** is a **Sinatra-like CoAP framework** for IoT and microservices in Ruby.  
It provides a lightweight way to build **CoAP APIs**, handle **IoT messaging**, and process sensor data efficiently.

🔹 **Minimalistic DSL** – Define CoAP endpoints just like in Sinatra.  
🔹 **CoRE discovery helpers** – Configure link-format metadata inline or at boot.  
🔹 **Efficient and fast** – Runs over UDP, ideal for IoT applications.  
🔹 **Reliable transport** – Supports CoAP over TCP (RFC 8323).  
🔹 **Built-in proxy** – Reverse and forward proxy with transport switching.  
🔹 **Unified cluster** – One worker count for all transports with supervised processes.

## Why "Takagi"?
The name **Takagi** is inspired by **Riyoko Takagi**, as a nod to the naming convention of Sinatra.
Just like Sinatra simplified web applications in Ruby, Takagi aims to simplify CoAP-based IoT communication in Ruby. It embodies minimalism, efficiency, and a straightforward approach to handling CoAP requests.
Additionally, both Sinatra and Takagi share a connection to **jazz music**, as Riyoko Takagi is a known jazz pianist, much like how Sinatra was named after the legendary Frank Sinatra.

---

## Philosophy

**Takagi treats CoAP as a first-class HTTP-equivalent protocol.**

CoAP (RFC 7252) was explicitly designed to mirror HTTP semantics for constrained environments. Yet most CoAP libraries (libcoap, aiocoap, californium) force developers into unfamiliar programming patterns that ignore decades of HTTP best practices.

Takagi rejects this approach. If CoAP is "HTTP for IoT," then CoAP servers should feel like HTTP servers. Routes, middleware, REST semantics—these patterns work. Why abandon them?

**Takagi brings Sinatra's elegance to CoAP.** If you can build a web API, you can build an IoT API.

---

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'takagi'
```

Or install it manually:

```sh
gem install takagi
```

---

## Getting Started

### **Create a new Takagi API**

Takagi provides a **Sinatra-like DSL** with modern Ruby conveniences:

```ruby
require 'takagi'

class SensorAPI < Takagi::Base
  # Simple GET with auto-extracted params
  get '/sensor/:id' do
    json id: params[:id], value: 22.5, status: 'active'
  end

  # POST with validation helpers
  post '/sensor' do
    validate_params :value  # Raises if missing

    created sensor_id: rand(1000), value: params[:value]
  end

  # Early returns with halt
  get '/restricted' do
    halt forbidden('Access denied') unless authorized?
    json message: 'Welcome'
  end

  # Delete with status helpers
  delete '/sensor/:id' do
    deleted message: "Sensor #{params[:id]} removed"
  end
end

SensorAPI.run!
# To serve CoAP over TCP instead of UDP:
# SensorAPI.run!(protocols: [:tcp])
# To serve both TCP and UDP simultaneously:
# SensorAPI.run!(protocols: [:udp, :tcp])
```
🔥 **Boom! You just built a CoAP API in Ruby.**

### **Structure a service with `Takagi::Application`**

For a modular service, put routes in controllers and mount them in an application. Concurrency belongs to the service, not to a controller:

```ruby
require 'takagi'

class TelemetryController < Takagi::Controller
  configure { mount '/telemetry' }

  get '/temperature' do
    json value: 21.5
  end
end

class SensorService < Takagi::Application
  configure do
    load_controllers TelemetryController
    threads 8       # serving threads inside each process
    processes 2     # OS workers for the whole service
  end
end

SensorService.run!(port: 5683, protocols: [:udp, :tcp])
```

`configure` also accepts `port`, `protocols`, `bind_address`, `max_connections`, `profile`, `protocol_settings`, and `set`. A `Takagi::Base` app writes the same keys in `takagi.yml`; controllers carry no `threads`/`processes` setting.

### **Deploy behind a proxy**

When you have multiple backends (one per service), use the built-in CoAP proxy to expose them at a single address:

```yaml
# proxy.yml
port: 5683
protocols: [udp, tcp]

proxy:
  enabled: true
  routes:
    - prefix: /sensors          # namespace: /sensors/temp -> /temp
      host: 192.168.1.10
      port: 5683
    - prefix: /management       # same-transport by default; TCP out here
      host: 192.168.1.11
      port: 5683
      outbound: tcp
    - prefix: /telemetry        # transparent: /telemetry/temp -> /telemetry/temp
      host: 192.168.1.12
      port: 5683
      strip_prefix: false
    - host: 192.168.1.13        # no prefix: any path -> the same path
      port: 5683
  names:
    - proxy.example.com
    - 192.168.1.1
  discovery: aggregate
  forward: configured
```

```ruby
require 'takagi'

Takagi.config.load_file('proxy.yml')

table = Takagi::Proxy::RouteTable.from_config(Takagi.config)
proxy = Takagi::Proxy.new(route_table: table,
                          port: Takagi.config.port,
                          protocols: Takagi.config.protocols)

Takagi.logger.info "proxy listening: UDP #{proxy.port(:udp)}, TCP #{proxy.port(:tcp)}"
proxy.run!
```

The proxy supports namespace (prefix), transparent, and catch-all routes, forward-proxy (Proxy-Uri/Proxy-Scheme), and transport switching per route so a UDP device can reach a TCP backend. With `discovery: aggregate`, prefixed routes rewrite backend links under their prefix while transparent routes leave the links exactly as the backend advertises them. See `CONFIGURATION.md` for the full proxy reference and `guide/proxy.md` for the task-oriented page.

### **Configure CoRE discovery metadata**

Expose meaningful attributes in `/.well-known/core` either inline or after registration:

```ruby
class SensorAPI < Takagi::Base
  get '/metrics' do
    core do
      title 'Environment Metrics'
      rt %w[sensor.metrics sensor.temp]
      interface 'core.s'
      sz 256 # expected size of data
    end

    { temp: 21.4, humidity: 0.48 }
  end
end

# Configure discovery data separately (e.g. in an initializer):
SensorAPI.core '/metrics' do
  title 'Environment Metrics'
  ct 'application/cbor'
end
```

Both approaches share the same DSL, so you can keep route handlers focused while still
publishing rich metadata.

### **But CoAP is not only GET, POST, PUT and DELETE. There is also Observe!**
```ruby
require 'takagi'

class SensorAPI < Takagi::Base
  topic "/sensors/temp", metadata: { rt: 'sensor.temp.streaming' } do
    { temp: 42.0, unit: 'celsius' }   # initial representation, produced once at boot
  end

  reactor do
    # observe: Client-side - subscribe to remote observable resources
    observe "coap://temp_server/temp" do |request, params|
      Takagi.logger.info "Remote temperature update: #{params.inspect}"
    end
  end
end

SensorAPI.run!
```
🔥 **Takagi is Observe (RFC 7641) enabled**

**Important distinction:**
- **`topic`** - Server-side: a state-carrying resource; a plain GET reads its current
  representation, a GET with `Observe: 0` registers the client
- **`observe`** - Client-side: Subscribe to remote observable resources

---

## Other features

Takagi provides a rich set of helper methods to make your code cleaner and more intuitive. 
Why? Because even if CoAP is like HTTP, then you should make new endpoints with ease.

### **Response Helpers**

Instead of manually constructing responses, use semantic helpers:

```ruby
class MyAPI < Takagi::Base
  get '/users' do
    json users: User.all  # Returns 2.05 Content
  end

  post '/users' do
    validate_params :name, :email
    created user_id: 123, name: params[:name]  # Returns 2.01 Created
  end

  put '/users/:id' do
    changed message: 'User updated'  # Returns 2.04 Changed
  end

  delete '/users/:id' do
    deleted message: 'User removed'  # Returns 2.02 Deleted
  end
end
```

**Available response helpers:**
- `json(data)` - 2.05 Content
- `created(data)` - 2.01 Created
- `changed(data)` - 2.04 Changed
- `deleted(data)` - 2.02 Deleted
- `valid(data)` - 2.03 Valid
- `respond(payload, code: 2.05, formats: [ct], force: nil)` - negotiate `Content-Format` via `Accept`/defaults and build the CoAP response for you. `formats` is the allowed list; `force` pins a format (e.g., SenML CBOR) and returns `4.15` if unsupported. Unsupported `Accept` yields `4.06`.
  - If you declare `ct` in your CoRE metadata, `respond` will use that as the allowed list automatically, so discovery and runtime stay in sync.

Quick examples:

```ruby
get '/sensor' do
  # Default (router content-format, typically JSON)
  respond(sensor: 22.5)
end

get '/sensor' do
  # Allow JSON or CBOR, honor Accept
  respond({ sensor: 22.5 }, formats: [
    CoAP::Registries::ContentFormat::JSON,
    CoAP::Registries::ContentFormat::CBOR
  ])
end

get '/senml' do
  # Force a required format (e.g., SenML CBOR)
  respond(senml_payload, force: CoAP::Registries::ContentFormat::CBOR)
end
```

### **Error Response Helpers**

Handle errors elegantly with built-in helpers:

```ruby
class MyAPI < Takagi::Base
  get '/resource/:id' do
    halt not_found("Resource #{params[:id]} not found") unless exists?(params[:id])

    json data: fetch_resource(params[:id])
  end

  post '/restricted' do
    halt unauthorized('Please authenticate') unless authenticated?
    halt forbidden('Insufficient permissions') unless authorized?

    created message: 'Success'
  end

  get '/validate' do
    halt bad_request('Invalid input') unless valid_input?

    json status: 'ok'
  end
end
```

**Available error helpers:**
- `bad_request(msg)` - 4.00 Bad Request
- `unauthorized(msg)` - 4.01 Unauthorized
- `forbidden(msg)` - 4.03 Forbidden
- `not_found(msg)` - 4.04 Not Found
- `method_not_allowed(msg)` - 4.05 Method Not Allowed
- `server_error(msg)` - 5.00 Internal Server Error
- `service_unavailable(msg)` - 5.03 Service Unavailable

### **Plugins**

Ship features as plugins under `Takagi::Plugins::<Name>` with `.apply(app, opts = {})`. Plugins can:
- Add routes/controllers (optionally auto-prefixed via `route_prefix` metadata)
- Register serializers/content-formats
- Register new transports/servers
- Extend CoAP registries (methods, responses, options, content-formats)
- Hook into lifecycle events (`docs/FIRST_PLUGIN_GUIDE.md`, `docs/HOOKS.md`)

Enable with `plugin :name, order: 0, **options` in your app and call `enable_plugins!`, or via config `plugins.enabled`. Use `dependencies: [{ name: :other, version: '>=1.0.0' }]`, `requires: '1.2.3'`, `config_schema` for validated options, and `route_prefix` to isolate plugin routes. See `docs/FIRST_PLUGIN_GUIDE.md` for a full walkthrough.

### **Parameter Validation**

Validate required parameters automatically:

```ruby
class MyAPI < Takagi::Base
  post '/sensor/reading' do
    # Raises ArgumentError if any parameter is missing
    validate_params :temperature, :humidity, :timestamp

    created(
      reading_id: save_reading(params),
      temperature: params[:temperature]
    )
  end
end
```

### **Auto-extracted Parameters**

Parameters are automatically available without explicit block arguments:

```ruby
class MyAPI < Takagi::Base
  # Before: Had to specify params in arguments
  get '/old/:id' do |request, params|
    { id: params[:id] }
  end

  # After: params available automatically!
  get '/new/:id' do
    json id: params[:id], name: "Resource #{params[:id]}"
  end

  # Still works with explicit args if needed
  get '/mixed/:id' do |request, params|
    json id: params[:id], method: request.method
  end
end
```

### **Request Inspection Helpers**

Easily inspect request properties:

```ruby
class MyAPI < Takagi::Base
  get '/data' do
    # Check request method
    return json(method: 'GET') if request.get?

    # Check Accept header
    if request.accept?('application/json')
      json message: 'JSON format'
    elsif request.accept?('application/cbor')
      json message: 'CBOR format'
    end
  end

  get '/search' do
    # Access query parameters
    query = request.query_params
    json query: query, results: search(query['q'])
  end

  post '/upload' do
    # Get content format
    format = request.content_format
    json received_format: format
  end
end
```

**Available request helpers:**
- `request.get?` / `post?` / `put?` / `delete?` / `observe?` - Check request method
- `request.accept?(format)` - Check if request accepts a format
- `request.content_format` - Get Content-Format option
- `request.query_params` - Get query parameters as hash
- `request.option(number)` - Get CoAP option by number
- `request.option?(number)` - Check if option exists

### **Early Returns with `halt`**

Use `halt` for cleaner early returns:

```ruby
class MyAPI < Takagi::Base
  get '/resource/:id' do
    halt not_found('Not found') unless exists?(params[:id])
    halt forbidden('Access denied') unless can_access?(params[:id])

    # Main logic only executes if checks pass
    json data: fetch_resource(params[:id])
  end
end
```

### **Topics (state-carrying resources)**

Offer a state-carrying resource to clients using the `topic` method. The declaration block
runs **once**, producing the initial representation; later reads serve that state and
publishing a new value is what observers are notified about:

```ruby
class MyAPI < Takagi::Base
  topic '/sensor/temp', metadata: { rt: 'sensor.temperature', obs: true } do
    { temperature: read_sensor, unit: 'celsius' }
  end

  reactor do
    # Client-side: Subscribe to a remote observable
    observe 'coap://remote-server/sensor' do |request, params|
      Takagi.logger.info "Received: #{params.inspect}"
    end
  end
end
```

**Note:**
- `topic` = Server-side: declares the resource and its current representation; a plain
  GET reads it, a GET with `Observe: 0` subscribes the client (RFC 7641)
- `observe` = Client-side (subscribe to remote resources)

---

## Sending Requests (Client API)

Takagi provides a unified, Ruby-idiomatic client API for sending CoAP requests over both UDP and TCP.

### **Unified Client with Auto-Cleanup**

The client follows Ruby conventions (like `File.open`) with block-based initialization for automatic resource cleanup:

```ruby
# Block-based initialization (recommended - auto-cleanup)
Takagi::Client.new('coap://localhost:5683') do |client|
  client.get('/temperature')
end # Automatically cleaned up

# Or with TCP
Takagi::Client.new('coap+tcp://localhost:5683') do |client|
  client.get('/temperature')
end

# Explicit protocol selection
Takagi::Client.new('localhost:5683', protocol: :tcp) do |client|
  client.get('/temperature')
end
```

### **Response Wrapper with Convenience Methods**

Responses are wrapped with intuitive status checking methods:

```ruby
Takagi::Client.new('coap://localhost:5683') do |client|
  client.get('/temperature') do |response|
    if response.success?
      puts "Temperature: #{response.payload}"
      puts "Status: #{response.code_name}"  # "2.05 Content"
    elsif response.not_found?
      puts "Resource not found"
    elsif response.error?
      puts "Error: #{response.code_name}"
    end
  end
end
```

**Available response methods:**
- **Status checking:** `success?`, `error?`, `client_error?`, `server_error?`
- **Specific codes:** `ok?`, `created?`, `deleted?`, `changed?`, `valid?`, `not_found?`, `bad_request?`, `unauthorized?`, `forbidden?`, `internal_server_error?`
- **Data access:** `payload`, `code`, `code_name`, `options`, `token`
- **JSON support:** `json`, `json?`, `content_format`

### **JSON Convenience Methods**

Simplified JSON handling with automatic encoding and decoding:

```ruby
Takagi::Client.new('coap://localhost:5683') do |client|
  # Automatic JSON encoding
  client.post_json('/data', {temp: 25, humidity: 60})

  # Automatic JSON parsing
  client.get_json('/data') do |data|
    puts data['temp']  # Already parsed!
  end

  # Or check content type manually
  client.get('/data') do |response|
    if response.json?
      data = response.json
      puts data['temp']
    end
  end
end
```

### **All HTTP-Like Methods**

The client supports all standard CoAP methods:

```ruby
Takagi::Client.new('coap://localhost:5683') do |client|
  # GET request
  client.get('/sensor/1') do |response|
    puts response.payload if response.success?
  end

  # POST request
  client.post('/sensor', 'temperature=25') do |response|
    puts "Created: #{response.created?}"
  end

  # PUT request
  client.put('/sensor/1', 'temperature=26') do |response|
    puts "Changed: #{response.changed?}"
  end

  # DELETE request
  client.delete('/sensor/1') do |response|
    puts "Deleted: #{response.deleted?}"
  end
end
```

### **Readable Default Output**

Without a block, responses print human-readable output:

```ruby
Takagi::Client.new('coap://localhost:5683') do |client|
  client.get('/resource')
  # Prints: [2.05 Content] Hello World

  client.get('/missing')
  # Prints: [ERROR 4.04 Not Found] Resource not available
end
```

### **Using `coap-client` CLI**

For quick testing, you can also use the standard CoAP command-line tools:

```sh
coap-client -m get coap://localhost:5683/sensor/1
```

```sh
coap-client -m post coap://localhost:5683/sensor -e '{"value":42}'
```

---

## Configuration

Takagi supports flexible configuration through YAML files, environment variables, and programmatic API. Configuration is applied in priority order: **YAML config** > **ENV variables** > **defaults**.

For the full configuration guide—including server settings (port, processes, threads, protocols), block-wise transfer tuning, EventBus tuning, proxy setup, and deployment profiles—see **`CONFIGURATION.md`**.

Quick preview:

```yaml
# takagi.yml
port: 5683
processes: 4          # OS worker processes for the whole service
threads: 4            # Threads per process
protocols: [udp, tcp]

block_wise:
  enabled: true
  szx: 6              # 1024-byte blocks
  max_assembled_bytes: 1048576
```

**Concurrency is a service setting.** An `Application` declares `threads`, `processes`, a `profile`, and the transport options in its `configure` block (explicit values win over a profile); a `Takagi::Base` app writes the same keys at the top level of `takagi.yml`. Controllers have no concurrency settings.

---

## CoAP Protocol Registry System

Takagi includes an extensible registry system for protocol constants, providing a plugin-friendly architecture where custom methods, response codes, options, and content formats can be registered.

## Plugin System

Takagi ships with an EventBus-backed plugin manager for runtime extensions. The bus delivers in-process only; remote or cross-process event delivery is planned, not present.

- **Auto-discovery**: Finds plugins under `Takagi::Plugins::*` and `takagi-plugin-*` gems (configurable via `plugins.auto_discover`).
- **Config + DSL**: Declare in code (`plugin MyPlugin, opt: 1`) or YAML:
  ```yaml
  plugins:
    auto_discover: true
    enabled:
      - name: request_logging
        options:
          sample_rate: 0.1
      - prometheus
  ```
- **Lifecycle hooks**: Plugins may implement `before_apply/apply/after_apply` (plus `before_unload/shutdown`). Events publish to `hooks.plugin_*` on the `Bus`.
- **Deps & versions**: `metadata` supports `dependencies:` and `requires:`; dependencies auto-enable first and versions are checked.
- **Config schema**: Optional `config_schema` validates types/enums/ranges and fills defaults before apply.
- **Hooked internals**: Core emits `hooks.*` for registry changes, route additions, middleware before/after, server start/stop, Observe subscribe/notify, all on the local bus.

Quick start:
```ruby
class MyApp < Takagi::Base
  plugin Takagi::Plugins::RequestLogging, sample_rate: 0.2
end

MyApp.run! # enables plugins from DSL + config
```

### **Using Protocol Constants**

All CoAP constants are organized into registries that follow RFC specifications:

```ruby
# Method codes (RFC 7252 §12.1.1)
Takagi::CoAP::Registries::Method::GET     # => 1
Takagi::CoAP::Registries::Method::POST    # => 2

# Response codes (RFC 7252 §12.1.2)
Takagi::CoAP::Registries::Response::CONTENT     # => 69 (2.05)
Takagi::CoAP::Registries::Response::NOT_FOUND   # => 132 (4.04)

# Options (RFC 7252 §5.10)
Takagi::CoAP::Registries::Option::URI_PATH         # => 11
Takagi::CoAP::Registries::Option::CONTENT_FORMAT   # => 12

# Content formats (RFC 7252 §12.3)
Takagi::CoAP::Registries::ContentFormat::JSON        # => 50
Takagi::CoAP::Registries::ContentFormat::TEXT_PLAIN  # => 0
```

### **Code Conversion Helpers**

Convert between different representations easily:

```ruby
# Convert code to human-readable string
Takagi::CoAP::CodeHelpers.to_string(69)      # => "2.05 Content"
Takagi::CoAP::CodeHelpers.to_string(:get)    # => "GET"

# Convert to numeric code
Takagi::CoAP::CodeHelpers.to_numeric(:get)       # => 1
Takagi::CoAP::CodeHelpers.to_numeric("2.05")     # => 69

# Status checking
Takagi::CoAP::Registries::Response.success?(69)        # => true (2.xx)
Takagi::CoAP::Registries::Response.client_error?(132)  # => true (4.xx)
```

### **Plugin Development**

Extend the protocol by registering new constants at runtime:

```ruby
# Register a custom method (RFC 8132 - FETCH)
Takagi::CoAP::Registries::Method.register(5, 'FETCH', :fetch, rfc: 'RFC 8132 §2')

# Now available as constant
Takagi::CoAP::Registries::Method::FETCH  # => 5

# Register custom response codes
Takagi::CoAP::Registries::Response.register(231, '7.07 Custom Code', :custom_code)

# Register custom options (e.g., for Block-Wise Transfer RFC 7959)
Takagi::CoAP::Registries::Option.register(23, 'Block2', :block2, rfc: 'RFC 7959 §2.2')
```

**Benefits:**
- Single source of truth for all CoAP constants
- Plugin-friendly architecture for extending with new RFCs
- Self-documenting code (no magic numbers)
- RFC-aligned structure with inline documentation
- Type-safe with validation methods

---

## Features & Modules

### Server Features

| Feature                          | Description | Status |
|----------------------------------|-------------|--------|
| **CoAP API (RFC 7252)**          | Define REST-like CoAP routes with Sinatra-like DSL | ✅ Ready |
| **CoRE metadata DSL (RFC 6690)** | Describe discovery attributes inline or at boot | ✅ Ready |
| **Observe (RFC 7641)**           | Offer server push and subscribe to remote feeds | ✅ Ready |
| **CoAP over TCP (RFC 8323)**     | Reliable transport for constrained clients | ✅ Ready |
| **Block-Wise Transfer (RFC 7959)** | Large payloads split into numbered blocks | ✅ Ready |
| **Proxy (RFC 7252 §5.7)**        | Namespace, transparent and catch-all routes; forward proxy (Proxy-Uri) | ✅ Ready |
| **Transport Switching**          | Route UDP clients to TCP backends and vice versa | ✅ Ready |
| **Unified Cluster**              | One worker count serves all transports; supervised processes | ✅ Ready |
| **Application service DSL**      | Controllers, app-level routes, and service-level threads/processes | ✅ Ready |
| **Response Helpers**             | Semantic helpers like `json`, `created`, `deleted` | ✅ Ready |
| **Error Helpers**                | Easy error responses with `not_found`, `forbidden`, etc. | ✅ Ready |
| **Auto-extracted Params**        | No need to specify params in block arguments | ✅ Ready |
| **Request Helpers**              | Inspect requests with `accept?`, `query_params`, etc. | ✅ Ready |
| **Validation Helpers**           | Validate params with `validate_params` | ✅ Ready |
| **Early Returns**                | Use `halt` for cleaner control flow | ✅ Ready |
| **Observable/Observe**           | Clear distinction: `observable` (server), `observe` (client) | ✅ Ready |

### Client Features

| Feature                          | Description | Status |
|----------------------------------|-------------|--------|
| **Unified Client API**           | Single interface for UDP and TCP with auto-protocol detection | ✅ Ready |
| **Block-based Initialization**   | Auto-cleanup with Ruby-idiomatic block pattern | ✅ Ready |
| **Response Wrapper**             | Convenient status checking with `success?`, `error?`, etc. | ✅ Ready |
| **JSON Convenience Methods**     | Automatic JSON encoding/decoding with `post_json`, `get_json` | ✅ Ready |
| **Block-Wise Support**           | Automatic multi-block upload/download over UDP | ✅ Ready |
| **Readable Default Output**      | Human-readable response formatting by default | ✅ Ready |
| **All CoAP Methods**             | Support for GET, POST, PUT, DELETE over UDP/TCP | ✅ Ready |

### Protocol & Extension Features

| Feature                          | Description | Status |
|----------------------------------|-------------|--------|
| **CoAP Registry System**         | Extensible registry for protocol constants | ✅ Ready |
| **Protocol Constants**           | RFC-aligned constants for methods, responses, options | ✅ Ready |
| **Code Helpers**                 | Convert between numeric codes and human-readable strings | ✅ Ready |
| **Plugin Architecture**          | Register custom methods, options, and response codes | ✅ Ready |
| **Block-Wise Transfer**          | RFC 7959 block options (Block1/Block2) for large payloads | ✅ Ready |
| **Proxy Option Handling**        | Proxy-Uri, Proxy-Scheme, Uri-* options per RFC 7252 §5.10 | ✅ Ready |
| **RFC Documentation**            | Inline RFC references for all constants | ✅ Ready |

---

## Architecture

### Unified cluster, one worker count per service

Takagi uses a single cluster to supervise all transports. When you set `processes: 4`, the service forks 4 OS worker processes and **every transport** (UDP, TCP, or both) is served by all of them. This means:

- One number decides the whole service concurrency, not per-protocol counts.
- Each worker serves every transport the service exposes.
- A crashed worker is reaped and replaced one-for-one.
- `processes: 1` runs everything in the booting process with no forks.

Per-transport knobs still exist for **threads** (handler pool size) and **max_connections** (TCP accepted-connection cap), but these layer under the one worker count.

Concurrency is declared on the service: an `Application` sets `threads`/`processes` in `configure`, a `Base` app in `takagi.yml`. There is no per-controller pool or process count.

### Proxy as a first-class component

The proxy is not an afterthought - it is a CoAP-native reverse+forward proxy that:
- Maps URI namespaces to backends (`proxy.routes`); `strip_prefix: false` keeps the client path and a route with no prefix is a transparent catch-all.
- Re-originates Message ID and Token per hop (never reuses them across hops).
- Switches transport per route (UDP in -> TCP out, and vice versa).
- Aggregates `/.well-known/core` from all backends when `discovery: aggregate`; prefixed links are rewritten under their prefix, transparent links are left unchanged.
- Honors Proxy-Uri / Proxy-Scheme for forward-proxy requests.
- Prevents request loops by recognizing its own names and rejecting self-routes.

The proxy passes Block1/Block2 through untouched and does not relay Observe subscriptions; each limitation is documented. See `CONFIGURATION.md` for the full proxy reference.

### Block-wise and per-hop reliability

Large payloads travel as numbered blocks (RFC 7959). The server slices large responses (Block2) and reassembles large requests (Block1). Because the proxy re-originates messages per hop, block-wise assembly and reliability are **per-hop** rather than end-to-end. This is consistent with RFC 8323's intermediary model.

---

## Contributing

Want to help? Fork the repo and submit a PR!

```sh
git clone https://github.com/domitea/takagi.git
cd takagi
bundle install
```

Run tests:
```sh
bundle exec rspec
```

---

## License

**MIT License**

---
