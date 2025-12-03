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
  reactor do
    # observable: Server-side - make a resource observable by clients
    observable "/sensors/temp" do
      core do
        title 'Temperature Stream'
        rt 'sensor.temp.streaming'
      end

      json temp: 42.0, unit: 'celsius'
    end

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
- **`observable`** - Server-side: Makes your resource observable by clients
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

### **Observable Resources**

Make resources observable by clients using the `observable` method:

```ruby
class MyAPI < Takagi::Base
  reactor do
    # Server-side: Offer an observable resource
    observable '/sensor/temp' do
      core { rt 'sensor.temperature'; obs true }
      json temperature: read_sensor, unit: 'celsius'
    end

    # Client-side: Subscribe to a remote observable
    observe 'coap://remote-server/sensor' do |request, params|
      Takagi.logger.info "Received: #{params.inspect}"
    end
  end
end
```

**Note:**
- `observable` = Server-side (offer observations to clients)
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

## CoAP Protocol Registry System

Takagi includes an extensible registry system for protocol constants, providing a plugin-friendly architecture where custom methods, response codes, options, and content formats can be registered.

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
| **Readable Default Output**      | Human-readable response formatting by default | ✅ Ready |
| **All CoAP Methods**             | Support for GET, POST, PUT, DELETE over UDP/TCP | ✅ Ready |

### Protocol & Extension Features

| Feature                          | Description | Status |
|----------------------------------|-------------|--------|
| **CoAP Registry System**         | Extensible registry for protocol constants | ✅ Ready |
| **Protocol Constants**           | RFC-aligned constants for methods, responses, options | ✅ Ready |
| **Code Helpers**                 | Convert between numeric codes and human-readable strings | ✅ Ready |
| **Plugin Architecture**          | Register custom methods, options, and response codes | ✅ Ready |
| **RFC Documentation**            | Inline RFC references for all constants | ✅ Ready |

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
