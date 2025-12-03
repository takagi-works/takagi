# Hooks for Plugins (EventBus-backed)

Hooks are published on the EventBus under `hooks.<event>` and delivered to local consumers. Subscribe with `Takagi::Hooks.subscribe(event) { |payload| ... }` (internally uses `EventBus.consumer`), emit with `Takagi::Hooks.emit(event, payload)`. Payloads are sent with `freeze_body: false` to avoid freezing mutable objects; keep payloads small and serializable for future clustering.

Current events and payloads:
- `:coap_registry_registered` — { registry:, value:, name:, symbol:, rfc: }
- `:coap_registry_cleared` — { registry: }
- `:router_route_added` — { method:, path:, entry: }
- `:middleware_before_call` — { request: }
- `:middleware_after_call` — { request:, response: }
- `:before_response_build` — { inbound:, result: }
- `:after_response_build` — { inbound:, response:, result: }
- `:server_starting` — { protocol:, port: }
- `:server_stopped` — { protocol:, port: }
- `:controller_workers_started` — { controller:, name:, threads: }
- `:controller_workers_stopped` — { controller: }
- `:observe_subscribed` — { path:, subscription: }
- `:observe_unsubscribed` — { path:, token: }
- `:observe_notify_start` — { path:, subscribers:, value: }
- `:observe_notify_end` — { path:, delivered:, value: }
- `:plugin_registered` — { name:, metadata: }
- `:plugin_enabling` — { name:, metadata:, options: }
- `:plugin_enabled` — { name:, metadata: }
- `:plugin_disabling` — { name:, metadata: }
- `:plugin_disabled` — { name:, metadata: }
- `:plugin_error` — { name:, metadata:, error: }

Notes:
- Handlers are executed in-process; errors are logged and swallowed.
- EventBus forwarding publishes to `hooks.<event>` by default when EventBus is loaded.
- Hook payloads are simple hashes to keep them Ractor-friendly later.
