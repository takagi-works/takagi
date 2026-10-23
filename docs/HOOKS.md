# Hooks for Plugins

Hooks and application events are the same kind of thing. One mechanism serves both: the local bus
(`Takagi.bus`), which is instance-owned and delivers in-process only. A hook is just a bus event
whose address carries the reserved `hooks.` prefix.

`Takagi::Hooks.subscribe(event) { |payload| ... }` registers a consumer on the bus under
`hooks.<event>` and returns the consumer id. `Takagi::Hooks.emit(event, payload)` publishes the
payload hash to that same address. Remove a subscriber with `Takagi::Hooks.unsubscribe(event, id)`,
passing back the id `subscribe` returned. Payloads are published with `freeze_body: false`, so a
mutable object reaches your subscriber unfrozen. Keep payloads small; they are plain Hashes.

## The `hooks.` prefix is reserved

`hooks.*` belongs to the hook dispatcher and to the plugins that subscribe through it. Treat it as a
namespace, not a routing hint. It must never acquire a transport binding:

- Nothing under `hooks.` is exposed as a CoAP observable, and nothing maps a `hooks.` address to a
  CoAP path.
- No remote, relay or cross-process delivery touches a `hooks.` address. The bus refuses a delivery
  scope it cannot perform, so asking for one raises rather than silently doing nothing.
- Hooks fire in the process that emits them. They never arrive on a pool thread, in a forked child or
  from a peer instance.

The two published plugins that ride this API (`takagi-plugin-sinatra` and `takagi-plugin-devtools`)
subscribe from their `apply` methods and rely on that in-process guarantee.

## Subscriber errors

A subscriber that raises is caught by the bus's own delivery. The caller of `emit` is not interrupted
and subscribers registered after the failing one still run. The error is logged, then re-emitted
through the hook path as:

- `:bus_subscriber_error` - `{ address:, subscriber_id:, error: }`

An error raised by a `:bus_subscriber_error` subscriber is swallowed too, so a broken error handler
cannot recurse.

## Current events and payloads

- `:coap_registry_registered` - `{ registry:, value:, name:, symbol:, rfc: }`
- `:coap_registry_cleared` - `{ registry: }`
- `:router_route_added` - `{ method:, path:, entry: }`
- `:middleware_before_call` - `{ request: }`
- `:middleware_after_call` - `{ request:, response: }`
- `:before_response_build` - `{ inbound:, result: }`
- `:after_response_build` - `{ inbound:, response:, result: }`
- `:server_starting` - `{ protocol:, port: }`
- `:server_stopped` - `{ protocol:, port: }`
- `:controller_workers_started` - `{ controller:, name:, threads: }`
- `:controller_workers_stopped` - `{ controller: }`
- `:observe_subscribed` - `{ path:, subscription: }`
- `:observe_unsubscribed` - `{ path:, token: }`
- `:observe_notify_start` - `{ path:, subscribers:, value: }`
- `:observe_notify_end` - `{ path:, delivered:, value: }`
- `:plugin_registered` - `{ name:, metadata: }`
- `:plugin_enabling` - `{ name:, metadata:, options: }`
- `:plugin_enabled` - `{ name:, metadata: }`
- `:plugin_disabling` - `{ name:, metadata: }`
- `:plugin_disabled` - `{ name:, metadata: }`
- `:plugin_error` - `{ name:, metadata:, error: }`
- `:block_transfer_started` - `{ direction:, num:, szx:, size:, path:, token: }`
- `:block_transfer_completed` - `{ direction:, num:, szx:, size:, path:, token: }`
- `:block_transfer_failed` - `{ direction:, num:, szx:, size:, path:, token:, reason: }`
- `:proxy_forwarded` - `{ target:, protocol:, token:, message_id:, backend: }`
  The forward proxy emits this once a backend has answered and the reply is about to be relayed
  (`lib/takagi/proxy/forwarder.rb`). `target:` and `backend:` both carry the backend authority as a
  `"host:port"` string; `protocol:` is the transport it was reached over, `:udp` or `:tcp`; `token:`
  is the backend reply's token and `message_id:` its message id. Because `Hooks.emit` publishes on
  the local, in-process bus, a proxy that serves inside a forked UDP worker fires this event in
  that child. Don't subscribe in a parent process and expect to see it: the event stays in the
  process that relays the reply.
- `:bus_subscriber_error` - `{ address:, subscriber_id:, error: }`

## What the bus does not do

- **No distribution.** `publish` delivers locally and in-process. It does not decide anything from an
  address, keeps no prefix table, and refuses a `:cluster` or `:global` scope with an
  `ArgumentError` naming the planned relay work. There is no cross-process, cluster or remote
  delivery here, and no placeholder that pretends otherwise.
- **Nothing reaches the CoAP bridge by itself.** Neither `publish` nor `consumer` touches
  `Takagi::Bus::CoAPBridge`, no observable resource is auto-registered, and the bridge reads no
  bus state. Registering an observable resource is an explicit
  `CoAPBridge.register_observable_resource(address, app)` call.
- **No event state or retention.** `publish` stores no last value, and there is no `current_state`,
  `message_store`, `replay` or `replay_to` on the bus. `Takagi::Bus::LRUCache`
  (`lib/takagi/event_bus/lru_cache.rb`) and `Takagi::Bus::MessageBuffer`
  (`lib/takagi/event_bus/message_buffer.rb`) stay as standalone, tested utilities with their own
  specs. Nothing in `lib/` references them until the state and relay layer that will consume them is
  built.
