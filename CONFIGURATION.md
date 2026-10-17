# Takagi Configuration Guide

Takagi supports flexible configuration through **YAML files**, **environment variables**, and **programmatic API**. Configuration is applied in priority order: **YAML config** > **ENV variables** > **defaults**.

## Table of Contents

1. [Quick Start](#quick-start)
2. [Configuration Methods](#configuration-methods)
3. [EventBus Configuration](#eventbus-configuration)
4. [Server Configuration](#server-configuration)
5. [Block-Wise Transfer Configuration](#block-wise-transfer-configuration)
6. [Proxy Configuration](#proxy-configuration)
7. [Environment Variables Reference](#environment-variables-reference)
8. [Examples](#examples)

---

## Quick Start

### 1. Using YAML Configuration (Recommended)

Create `takagi.yml` in your project root:

```yaml
port: 5683
threads: 4

event_bus:
  ractors: 10
  state_cache_size: 1000
  state_cache_ttl: 3600
  message_buffering_enabled: true
  message_buffer_max_messages: 100
  message_buffer_ttl: 300
```

Load the configuration:

```ruby
require 'takagi'

# Load configuration file
Takagi.config.load_file('takagi.yml')

# Configuration is now applied automatically
# Start your server or use EventBus
```

### 2. Using Environment Variables

```bash
export EVENTBUS_RACTORS=10
export EVENTBUS_STATE_SIZE=1000
export EVENTBUS_STATE_TTL=3600

ruby your_app.rb
```

### 3. Programmatic Configuration

```ruby
require 'takagi'

# Configure via API
Takagi.config.port = 5683
Takagi.config.event_bus.ractors = 10
Takagi.config.event_bus.message_buffering_enabled = true

# Or configure EventBus directly
Takagi::EventBus.enable_message_buffering(max_messages: 100, ttl: 300)
```

---

## Configuration Methods

### Priority Order

1. **YAML Configuration** (`takagi.yml`) - Highest priority
2. **Environment Variables** - Medium priority
3. **Defaults** - Lowest priority

### Loading YAML Configuration

```ruby
# Load from default path
Takagi.config.load_file('takagi.yml')

# Load from custom path
Takagi.config.load_file('/etc/takagi/config.yml')

# Load with error handling
begin
  Takagi.config.load_file('takagi.yml')
rescue Errno::ENOENT
  puts "No config file found, using defaults"
end
```

### Accessing Configuration

```ruby
# Access built-in settings
Takagi.config.port                    # => 5683
Takagi.config.threads                 # => 4
Takagi.config.event_bus.ractors       # => 10

# Access custom settings
Takagi.config[:app_name]              # => "My App"
Takagi.config.app_name                # => "My App" (method_missing)
```

---

## EventBus Configuration

### Core Settings

| Setting | YAML Key | ENV Variable | Default | Description |
|---------|----------|--------------|---------|-------------|
| **Worker Pool** | `event_bus.ractors` | `EVENTBUS_RACTORS` | 10 | Number of worker threads for async delivery |
| **State Cache Size** | `event_bus.state_cache_size` | `EVENTBUS_STATE_SIZE` | 1000 | Max addresses in LRUCache |
| **State Cache TTL** | `event_bus.state_cache_ttl` | `EVENTBUS_STATE_TTL` | 3600 | Seconds (1 hour) |
| **Cleanup Interval** | `event_bus.cleanup_interval` | `EVENTBUS_CLEANUP_INTERVAL` | 60 | Seconds between observer cleanup |
| **Max Observer Age** | `event_bus.max_observer_age` | `EVENTBUS_MAX_OBSERVER_AGE` | 600 | Seconds (10 minutes) |

### Message Buffering Settings

| Setting | YAML Key | Default | Description |
|---------|----------|---------|-------------|
| **Enable Buffering** | `event_bus.message_buffering_enabled` | false | Enable message buffering |
| **Max Messages** | `event_bus.message_buffer_max_messages` | 100 | Messages per address |
| **Buffer TTL** | `event_bus.message_buffer_ttl` | 300 | Seconds (5 minutes) |

### Configuration Examples

#### Minimal (Default)
```yaml
event_bus:
  # Use all defaults
  # - 10 workers
  # - 1000 address cache
  # - No message buffering
```

#### Moderate (WiFi Network)
```yaml
event_bus:
  ractors: 10
  state_cache_size: 1000
  state_cache_ttl: 3600

  # Enable buffering for WiFi reliability
  message_buffering_enabled: true
  message_buffer_max_messages: 50
  message_buffer_ttl: 60  # 1 minute
```

#### Heavy (Mesh Network)
```yaml
event_bus:
  ractors: 20  # More workers for high load
  state_cache_size: 5000
  state_cache_ttl: 7200  # 2 hours

  # Large buffer for poor connectivity
  message_buffering_enabled: true
  message_buffer_max_messages: 200
  message_buffer_ttl: 600  # 10 minutes
```

#### Memory Constrained (IoT Device)
```yaml
event_bus:
  ractors: 2  # Minimal workers
  state_cache_size: 100
  state_cache_ttl: 600  # 10 minutes

  # No buffering on constrained device
  message_buffering_enabled: false
```

### Programmatic EventBus Configuration

```ruby
# Enable message buffering at runtime
Takagi::EventBus.enable_message_buffering(
  max_messages: 100,
  ttl: 300
)

# Disable buffering
Takagi::EventBus.disable_message_buffering

# Use custom store (plugin)
Takagi::EventBus.configure_message_store(RedisMessageStore.new)

# Query configuration status
stats = Takagi::EventBus.stats
puts stats[:message_buffer]  # => { enabled: true, total_messages: 47, ... }
```

---

## Server Configuration

### Basic Settings

| Setting | YAML Key | Default | Description |
|---------|----------|---------|-------------|
| **Port** | `port` | 5683 | CoAP server port. `0` asks the kernel for a free port; each transport reports the port its own socket bound, in the boot log, in its own `:server_starting` payload and in the service's `:service_starting` payload |
| **Server Name** | `server_name` | nil | Server identification |
| **Processes** | `processes` | 1 | OS worker processes for the WHOLE service: the ONE count the cluster forks and every transport is served by. A per-protocol `processes` is only a compatibility alias that must agree (see [One worker count per service](#one-worker-count-per-service-processes)) |
| **Threads** | `threads` | 1 | Threads per serving process. A server-wide default for UDP's readers; a TCP handler pool opens only on the protocol's own key (see [Threads](#threads-threads)) |
| **Max Connections** | `max_connections` | nil (unlimited) | Accepted-connection cap per worker, for the **TCP** server (see [Per-worker connection cap](#per-worker-connection-cap-max_connections)) |
| **Protocols** | `protocols` | [:udp] | Supported protocols (`udp`, `tcp`) |
| **Protocol Settings** | `protocol_settings` | {} | Per-protocol overrides of `threads` and `max_connections`. A `processes` here is a compatibility alias that must restate the service's single count |

```yaml
port: 5683
server_name: "Building A Sensor Hub"
protocols:
  - udp
  - tcp

# Server-wide defaults
processes: 1
threads: 4
max_connections: 100
```

Concurrency has two scopes. `processes` is the service's ONE worker count: the cluster forks that many OS processes and every transport the service exposes is served by all of them, so it is not a per-transport knob. `threads` sizes a serving pool inside each process, and `max_connections` caps accepted connections. Only `max_connections` is TCP-specific, because UDP has no accepted-connection notion. A controller cannot take `max_connections`: it holds no accepted connections, so `set :max_connections, N` is refused rather than accepted and ignored (see [Per-worker connection cap](#per-worker-connection-cap-max_connections)).

### One worker count per service (`processes`)

`processes` is the number of OS worker processes the cluster forks for the WHOLE service, and every transport a service exposes is served by that same set of processes. A worker serves a whole transport, not a controller: every controller's routes are dispatched inside whichever worker accepted the request, so per-controller process isolation is not available in-process. One count, one precedence:

| Layer | Role |
|-------|------|
| top-level `processes` | THE service count. Default `1` |
| `protocol_settings[<transport>][:processes]` | a compatibility alias: accepted when it restates the service count, refused when it disagrees |

`ServerLifecycle#resolve_service_processes!` reads every count the configuration actually WROTE, once, before any server exists (`server_lifecycle.rb:221`, `:233`), takes that single value when the layers agree, and takes the lone written count when only one layer carries one.

When two written counts disagree the boot fails instead of quietly picking a winner. The raise names each layer and its value, then restates the rule and the remedy (`server_lifecycle.rb:244`):

```text
a service has ONE worker count, but the configured counts disagree: the top-level `processes` = 4 and
protocol_settings[:tcp][:processes] = 8. `processes` is the number of OS processes the cluster forks for
the whole service, so every transport it exposes serves the same count; a per-protocol `processes` is
accepted only when it restates that one count. Keep one number - write `processes: <N>` at the top level,
or make every `protocol_settings[<transport>][:processes]` agree - and use
`protocol_settings[<transport>][:threads]` for per-transport concurrency.
```

It fires at build time, in the same place the `max_connections` refusal does, so a misconfigured service fails before a single fork (`server_lifecycle.rb:261`).

```yaml
port: 5683
protocols: [udp, tcp]

processes: 4          # the service forks 4 workers; BOTH transports are served by all 4

protocol_settings:
  tcp:
    threads: 4        # a per-transport pool on the TCP side; the worker count above is unchanged
```

A `protocol_settings[:udp][:processes]` that restates the same number is accepted, so a configuration written under the old per-protocol shape keeps working as long as its counts agree.

**Count 1 forks nothing.** The default is the in-process shape on every transport: the booting process runs each transport's serve loop itself and starts no children (`cluster.rb:74`; the datagram loop's own comment states the same at `udp.rb:99-100`).

**Above 1, the booting process is the cluster master.** It forks `count` children indexed `0..count-1` (`cluster.rb:216`, `:226-231`), and the master binds every socket once, before any fork, so each child inherits all of them and serves EVERY transport the service exposes.

The lifecycle each transport guarantees:

| Transport | One unit of work | Default serving shape | Declared in-flight window | Worker count |
|-----------|------------------|-----------------------|---------------------------|--------------|
| UDP | one datagram (`udp.rb:155`) | `threads` reader threads per process | `DRAIN_DEADLINE` = 1.0 s (`udp.rb:20`, `udp_worker.rb:20`) | the service `processes` |
| TCP | one connection (`tcp.rb:205`) | thread per connection; a bounded handler pool only on a written `protocol_settings[:tcp][:threads]` (`tcp.rb:390`) | `POOL_JOIN_TIMEOUT` = 1.0 s (`tcp.rb:22`) | the service `processes` |

A child that dies is reaped and replaced one-for-one, with exactly one WARN per death naming the dead pid, its index, its status and the replacement's pid (`cluster.rb:319`), and the master ends LOUDLY when the last child is gone (`cluster.rb:267`, `:324`).

### Port reporting and the boot surface

Each transport reports the port its OWN socket bound, not the one that was requested. With `port: 0` the kernel picks a free port per socket, so UDP and TCP can end up on different ports, and the socket is the only honest source: `Server::Tcp#bound_port` reads `@server.addr[1]` (`tcp.rb:40`) and `Server::Udp#bound_port` reads `@socket.addr[1]` (`udp.rb:38`). Each transport's own `:server_starting` payload carries that value (`tcp.rb:155`, `udp.rb:103`).

On top of the per-transport payloads there is ONE boot surface per service: the `:service_starting` hook payload and one boot log line, carrying the transport set, the service's worker count and every transport's bound port with the serving pid (`server_lifecycle.rb:334`, `:346`). It asks each transport for its own `bound_port` through `bound_port_of` (`server_lifecycle.rb:357`), so the service surface and the transport payloads can never disagree, and `port: 0` no longer reports `0` anywhere (`port: 0` at the defaults table above).

### Readers and shutdown

Every transport of a service is supervised by the ONE cluster (`multi.rb:34`), and each is handed that cluster as its supervisor (`multi.rb:41`), so a transport's readers report the service's cluster and never a per-transport one it built: `srv.cluster` and `srv.worker_pids` answer the service's supervisor (`tcp.rb:29`, `:47`; `udp.rb:45`), and `Multi#worker_pids` reports the same list for the whole service (`multi.rb:48`).

Shutdown is per transport, not per service. `srv.shutdown!` on ONE transport stops THAT transport only - the cluster it built is the one it stops, and the service's cluster is the service's business (`tcp.rb:183`, `udp.rb:127`). `Multi#shutdown!` stops the service: the cluster first, then each transport's own teardown, so every transport emits its own stop (`multi.rb:79-82`). One consequence of the seam: TCP's `:server_stopped` now fires for a multi-transport service too, once per server (`tcp.rb:190-193`), where before it was emitted at the end of `run!`, which a fan-out never calls.

### The drain contract

Every transport declares a drain deadline to the cluster: the time in-flight work may take to finish once the transport is stopped. Today both declare `1.0` s. The master's batch deadline, `Cluster::WORKER_TERM_TIMEOUT`, is `2.0` s and is STRICTLY greater (`cluster.rb:42`), a relation `Cluster#assert_drain_fits_the_batch` asserts at construction and refuses to let a service violate - the raise names the adapter, the deadline and the batch (`cluster.rb:137`, `:142`). So on a stop the order is fixed:

1. The child stops accepting new work.
2. It finishes in-flight work inside the deadline it declared: UDP handles the datagrams already received and joins its reader threads inside `DRAIN_DEADLINE` (`udp_worker.rb:69`, sentinel at `:24`); TCP joins its handler threads inside `POOL_JOIN_TIMEOUT` (`tcp.rb:337`).
3. A straggler still holding work at the declared deadline is signalled, not waited on.
4. KILL is the master's last resort, and it only lands past the batch deadline (`cluster.rb:42`).

The TCP half covers BOTH shapes, and that coverage was a fix: the pool path joins its handler threads (`tcp.rb:329`), and the default thread-per-connection path joins the connection threads instead (`tcp.rb:354`). Before that fix a thread-per-connection TCP deployment lost in-flight work on stop. Measured on the PRE bytes: the response was LOST and the children were gone at `0.1013` s against the declared `1.0` s. On the shipped bytes the same exchange's response arrives at `0.3049` s and the child exits at `0.3073` s, inside the deadline, while a handler that never releases exits at `1.0975` s - the drain waits out its own `1.0` s, signals the straggler, and still leaves inside the master's `2.0` s batch. The measurements are in `.omo/evidence/task-13-verification-unified-cluster.txt` (md5 `e10b98a81223ca79a3bad3324cd450d9`) and pinned by the 11 examples of `spec/unit/drain_contract_spec.rb` (3 of them new for this shape).

### Migrating from per-protocol counts

The count semantics changed. Before this change a protocol could fork its own number of workers, and only UDP consumed the global `processes`; the per-protocol key was the rule. Now there is ONE count per service:

- An existing config that writes `protocol_settings[:tcp][:processes]` (or `[:udp][:processes]`) still works when its counts all agree: the per-protocol value is accepted as an alias that restates the service count.
- A config whose top-level `processes` and per-protocol `processes` differ now fails at boot with the refusal quoted above, naming both values. Keep one number, or make them agree.
- Process titles changed. They used to be `takagi-worker-tcp-<index>` on TCP and a bare `takagi-worker` on UDP; every worker of every transport is now titled `takagi-worker-<index>` (`cluster.rb:50`, `:231`). An operator's `pgrep -f '^takagi-worker'` still finds every worker, but a transport-scoped `pgrep`/`pkill` by title no longer separates them - read each service's own `srv.worker_pids` instead (`multi.rb:48`).

### Threads (`threads`)

`threads` exists on two levels that do not compete: a server's serving pool, and a controller's own pool.

**Server level.** UDP's readers always take the resolved value, that is `protocol_settings[:udp][:threads]` when written and the global `threads` otherwise. The TCP handler pool is opt-in on the protocol's OWN key: only a written `protocol_settings[:tcp][:threads]` opens one, because putting a bounded pool under a deployment that wrote only the global value would change how it serves (`server_lifecycle.rb:155`, `:170`). Thread-per-connection stays the default TCP shape; `protocol_settings[:tcp][:threads]` is how a dual-transport service asks for a bounded TCP pool.

When a pool is open it is bounded: that many threads pull accepted sockets from a queue and run the same handler the thread-per-connection model runs, and a connection that finds every thread busy waits in the queue rather than being refused. Two configurations keep today's thread-per-connection SERVING model unchanged: `threads` unset (no pool is started), or `threads` at or above `max_connections` (such a pool could not bound concurrency below what the connection cap already bounds) - `tcp.rb:390-395`. Serving is identical; the stop path is not. A thread-per-connection server now drains its in-flight connections against the declared `1.0` s deadline before it exits (`drain_connections`, `tcp.rb:354`), where before the fix it dropped them at about `0.10` s: measured, the PRE bytes lost the response with the children gone at `0.1013` s, while the shipped bytes deliver that response at `0.3049` s with the child exiting at `0.3073` s, inside the deadline (`.omo/evidence/task-13-verification-unified-cluster.txt`, md5 `e10b98a81223ca79a3bad3324cd450d9`).

**Controller level.** A controller's own `threads` (its `set :threads, N`, or its profile's count) is its own pool; no server-wide value overrides it, and it is the per-endpoint lever (`controller.rb:152-168`). The allocation that starts those pools reads `[:threads]` and nothing else, so a `processes` value declared on a controller is not a worker count (`application.rb:126-155`, `resource_allocator.rb:88-104`).

### Per-worker connection cap (`max_connections`)

`max_connections` governs the **TCP server only**: UDP has no accepted-connection notion, and a UDP server is never given the key (`server_lifecycle.rb:163`). A controller can never carry this key: `set :max_connections, N` raises `ArgumentError` naming the controller and the reason, because a controller holds no accepted connections and no code reads it back (`controller.rb:336-352`), while the server-level `max_connections` documented here is the TCP server's per-worker accepted-connection cap.

Under more than one worker the number is **per worker**, so the effective ceiling of one server is `worker_processes x max_connections`. Each worker counts only the connections it accepted and served, and the master counts none - there is no cross-process counter, so this is a per-worker guarantee and never a global one (`tcp.rb:404-419`).

Measured on real sockets: two workers with `max_connections: 1` hold two connections at once, and with `max_connections: 2` four, each connection held by a distinct worker pid while the master's own count stays 0 (`spec/unit/tcp_workers_spec.rb:1182-1256` - the `assert_worker_cap` helper and its two `worker_processes: 2` examples, with the master's own count asserted at `:1216`).

**Queue versus refuse.** Below its cap a worker accepts the connection and, when every handler thread is busy, QUEUES it rather than refusing it (`tcp.rb:273-277`). Only a connection that arrives once that worker's own cap is reached is refused, with a WARN line naming the limit and an immediate EOF to the client (`tcp.rb:257-260`).

```yaml
protocol_settings:
  tcp:
    threads: 4           # bounded handler pool, per worker
    max_connections: 16  # per worker; 4 workers -> 64 accepted connections at once
```

### Process titles and supervision

A forked worker names itself for the SERVICE, not for a transport. Every child of every transport is titled `takagi-worker-<index>`, with no transport in the name (`cluster.rb:50`, `:231`):

| Service | Process titles |
|---------|----------------|
| one worker (`processes: 1`) | none: the worker runs in the booting process |
| N workers | `takagi-worker-0` ... `takagi-worker-<N-1>` |

One anchored pattern still matches every worker, and it is now the same pattern for both transports:

```bash
pgrep -f '^takagi-worker'         # every worker of the service, on every transport
```

To tell which transport a worker is serving, ask the service rather than the process table: `srv.worker_pids` lists the supervised pids by fork order (`multi.rb:48`).

Supervision is one-for-one. A child that dies is reaped and replaced by a new one carrying its index, and the death is logged with exactly one WARN naming the dead pid, its index, its status and the replacement's pid (`cluster.rb:319`). When the last child is gone there is nobody left to serve with, so supervision ends and the master reports it LOUDLY (`cluster.rb:267`, `:324`).

### Boot validation of concurrency keys

`build_servers` checks a protocol's concurrency keys before it instantiates that protocol's server (`server_lifecycle.rb:119`, the check at `:125`), and a server binds only after that, so anything rejected here fails the boot before a socket exists (`tcp.rb:137` and `udp.rb:82` are the binds; measured: for a rejected configuration `Server::Registry.build` is never called and no `TCPServer` or `UDPSocket` is opened).

**A per-protocol key that its target cannot apply stops the boot.** Writing a per-worker connection cap for a datagram transport raises `ArgumentError` (`server_lifecycle.rb:261-273`):

```
protocol_settings[:udp][:max_connections] cannot apply to the :udp target: `max_connections` is the
TCP server's per-worker accepted-connection cap, and :udp accepts no connections, so the written
value would be dropped in silence. Scope such a cap to the server that accepts connections:
`protocol_settings: { tcp: { max_connections: <N> } }`.
```

The message names the key path, the target and the reason, and ends with the per-protocol line that can take the key. The same key written under `protocol_settings[:tcp]` is honoured.

**A global key the target cannot consume is reported once per boot, per key.** Each combination names the key, the protocol and the line to write instead:

| Written global key | Target that cannot consume it | Warning site |
|---|---|---|
| `threads`, any written value (the default `1` included) | `:tcp` | `server_lifecycle.rb:298` |
| `max_connections` | `:udp` | `server_lifecycle.rb:282` |

Each warning triggers on the key's PRESENCE, not on its value: a written `threads: 1` with a TCP target warns exactly once, and an omitted key warns zero times (`server_lifecycle.rb:300`, reading the presence carrier at `config.rb:413-443`, which `Config#reset_written_keys!` clears again). Measured: `threads: 6` together with `max_connections: 5` and `protocols: [udp, tcp]` produces exactly two warnings, one naming each key, and a configuration that writes neither produces none. `processes` is deliberately NOT in this table any more: a written global count is no longer unconsumed by TCP, because every transport serves the service's one count (see [One worker count per service](#one-worker-count-per-service-processes)).

**Where this validation does not reach.** Three edges are worth knowing:

- It is a boot-time check, not a parse-time one: `Config#load_file` stores `protocol_settings` exactly as written (`config.rb:323-337`) and raises nothing, so a linter that only loads the file reports no error - the rejection happens when a server is built.
- A protocol whose server is not registered is treated as capable and its per-protocol key is then ignored: `accepts_max_connections?` asks the registry, `Server::Registry.get` raises `NotFoundError` for an unknown target (`registry/base.rb:38`, `:87`) and the rescue answers "capable" (`server_lifecycle.rb:316-324`). `protocol_settings[:unknown][:max_connections]` therefore changes nothing; the failure surfaces only if that protocol is actually built, as the registry's own `Unknown protocol: unknown` (`server/registry.rb:59`).
- A server whose constructor takes `**options` is treated as capable too (`server_lifecycle.rb:321`), which would mask a future transport swallowing the key: measured with a `**options` server, the key raises nothing and the constructor receives `{port: 0}` - `max_connections` is attached for `:tcp` only (`server_lifecycle.rb:163`).

**Type-level checks.** `steep check` cannot tell you anything about the Ruby code in this checkout: it exits `1` having reported only signature-set problems, never a `lib/` file (measured: the progress line carries 72 marks, the number of `sig/**/*.rbs` files, and no mark for any of the 103 `lib/**/*.rb`; the single error today is `sig/takagi.rbs:2:2: Declaration of ::Takagi::VERSION is duplicated`, and with that line removed from a copy the same run reports six `sig/`-only unknown-type errors such as `Cannot find type Forwardable`). Treat a `steep` run here as inert, never as a clean typecheck; `rbs parse` is the syntactic check that does run.

### Forked workers: what a child owns

Both transports are served by the same cluster, which forks the workers (`cluster.rb:216`, `:226`). A `fork` copies the parent's memory but only the CALLING thread: every other thread the parent had is gone in the child, while the objects those threads were driving remain as data. That one fact decides, item by item, what a forked worker owns:

1. **Its own connection accounting.** The `max_connections` counter is per serving process: it is initialised on the server instance (`tcp.rb:124-125`), incremented and released only by the process that accepts and serves (`tcp.rb:404-419`), and the master never accepts at all - the cluster's supervision loop forks and reaps and never enters the accept loop (`cluster.rb:261`) - so a child starts from zero. No counter is shared and none needs to be, so the ceiling stays `worker_processes x max_connections` and never becomes global. Measured by the multi-worker specs, which hold `2 x 1` and then `2 x 2` connections at once from distinct worker pids while the master's own count stays `0` (`spec/unit/tcp_workers_spec.rb:1182-1256` - the `assert_worker_cap` helper and its two `worker_processes: 2` examples, with the master's own counter asserted at `:1216`).
2. **`Observable::Registry` and `Observer::Watcher` are parent-owned and absent in a child.** Both drive their work on threads - the watcher starts one (`observer/watcher.rb:13-17`) and the registry starts only what it already holds (`observable/registry.rb:47-64`) - and threads do not survive `fork`. A forked child never starts them in any case: `@watcher.start` appears only in `start_service_hooks!` (`tcp.rb:67`), which a service's fan-out calls once in the booting process (`multi.rb:56-60`), while a forked child runs `serve_all` (`cluster.rb:174`) into the transport's `serve_loop`, which for TCP is `accept_loop` (`tcp.rb:234`). One layer down it is the same story: hooks are delivered through the EventBus thread executor (`hooks.rb:51-78`) whose `running?` is a flag rather than a liveness check (`event_bus/async_executor.rb:30`, `:39`), so a child still answers "ready" while every executor thread is dead and a published hook lands in a queue with no drainer. Measured in a forked child: `Thread.list.size == 1`, all ten executor threads `alive? == false`, `Observable::Registry.registered?(:probe)` still answered `true` and the reactor still answered `running? == true` (the parent's flag, inherited as data), and a published hook raised the executor queue to 1 without its subscriber ever being called. The practical consequence is the one to remember: `:server_starting` and `:server_stopped` are emitted by the master's own `run!` (`tcp.rb:155`, `:193`; `udp.rb:103`, `:136`), which a child never calls, so they describe the master. Measured with three TCP workers: the hook fired twice, both times from the master's pid, while all three worker pids emitted nothing (a control child that deliberately emits is observed, so the channel is live in a child).
3. **A child inherits a controller pool object whose threads are dead, and its own copy of the Block1 assembly table.** The Block1 table is per process (see [Block-Wise Transfer Configuration](#block-wise-transfer-configuration)), and a controller pool is worse than absent in a child: it exists as an object whose threads died with the fork. `ThreadPool` records the pid that created it (`controller/thread_pool.rb:30`), `running_in_this_process?` reports that honestly (`:86-88`) and `Controller#workers_running?` asks it (`controller.rb:238`). The request path respects that answer - a forked UDP worker serves synchronously instead of queueing into a queue nobody drains (`udp_worker.rb:182-190`), and TCP runs the handler body directly rather than through a controller pool (`tcp.rb:295`) - and the reactor now asks the same question before it schedules, so a forked child runs observer work in the calling thread instead of queueing it into a pool whose drainer died (`observable/reactor.rb:470-477`, see [Observability](#observability)). Because the table and the pools are per process, a multi-worker TCP deployment carries a **narrower** version of the 4.08 exposure the UDP section describes: a TCP worker owns a connection for that connection's whole lifetime - the accepted socket is handed to exactly one handler (`tcp.rb:273-277`), which then runs that connection to its end (`:295`) - so only a block sequence whose blocks arrive on DIFFERENT connections can be split across workers, while for UDP every datagram of an upload may land on any worker - and the service's `processes` count is what multiplies those UDP workers, so more workers mean proportionally more of that risk. Nothing in this configuration can widen the TCP exposure further: a controller's `threads` sizes a pool, it does not decide which worker serves a connection, and no controller setting can reach the assembly key (`middleware/block_wise.rb:31`). Nor can Takagi's own TCP client create such a split sequence: it reports no block-wise support at all (`tcp_client.rb:88-94`, `block_wise_transport?` is `false`, with RFC 8323 block-wise over TCP deliberately unimplemented), and the TCP server's CSM advertises Max-Message-Size only, withholding Block-Wise-Transfer on purpose (`tcp.rb:582-600`). The exposure is therefore unchanged by any worker count you write, and nothing here raises one behind your back: `processes` is the only source of workers, while a controller's `threads` buys a pool and no longer implies a process count at all (`resource_allocator.rb:59-104` computes thread counts and carries no `:processes` key).
4. **Its own signal handling, made safe by a sticky flag.** Every serving process answers TERM/INT through the cluster: the master arms `trap('TERM')`/`trap('INT')` before any fork (`cluster.rb:158-160`), and a forked child re-arms the same handlers in its own state reset (`cluster.rb:252`). A stop a SIGNAL asked THIS process for is recorded on the process for its whole life (`@signal_stop`), so it outlives that reset: the child's reset drops the MASTER's stop state but must not drop the child's own stop (`cluster.rb:108`, `:166`). This is the fix for the race where a TERM landing between the fork and the reset was cleared, leaving the worker serving until the master's KILL (`cluster.rb:241-243`).
5. **No upper bound on a controller's `threads`.** `Controller#start_workers!` builds a pool of exactly the declared size (`controller.rb:198-206`) and profile validation accepts any count `>= 1` (`profiles.rb:138-153`), so a large `threads` allocates that many threads on a small device with no cap. Recorded, not capped here.

### Observability

```yaml
observability:
  backends:
    - memory
    # - prometheus
    # - statsd
```

**The reactor's pool is ownership-aware (row 26).** A reactor with an associated controller shares that controller's pool OBJECT (`observable/reactor.rb:147`), but it no longer schedules into it blindly: every schedule site (`:295`, `:328`, `:349`, `:383`) goes through `Reactor#schedule_in_pool` (`:470-477`), which asks `ThreadPool#running_in_this_process?` first - the same question the request path asks through `Controller#workers_running?` (`controller.rb:238`, `controller/thread_pool.rb:86-88`) - and only then pushes to the pool. A reactor that declares its own thread count builds an independent pool instead (`observable/reactor.rb:170-173`), created wherever the reactor is constructed - at boot, in the parent - so a child is in the same position. In a forked child the pool's threads are gone, so `reactor.notify` - documented for use from a request handler (`observable/reactor.rb:341-348`) - would have queued work nothing drains; the child now runs the observer work in the calling thread instead, exactly as a forked UDP worker serves a request synchronously (`udp_worker.rb:182-190`), so the notification's side effect still happens exactly once. Measured in a forked child: the pool reported `running_in_this_process? == false` with every pool worker `alive? == false`, and `reactor.notify` then called the observer's own handler inside the child - while in the parent, which owns the pool, the same call is delivered through the pool as before.

### Custom Settings

```yaml
custom:
  app_name: "My IoT Application"
  max_devices: 100
  device_timeout: 30
  api_key: "secret123"
```

Access custom settings:

```ruby
Takagi.config[:app_name]        # => "My IoT Application"
Takagi.config.max_devices       # => 100
Takagi.config.api_key           # => "secret123"
```

---

## Deployment Profiles

The concurrency knobs combine into two shapes. The choice is about where a device sits, not about which keys exist.

### Replica behind a proxy

A managed fleet puts a proxy or load balancer in front of several identical replicas, each replica doing real work but none owning the supervision of the others. The proxy is the fleet's supervisor; the replica is a single self-contained process:

```yaml
port: 5683
protocols: [udp, tcp]

processes: 1            # one process per replica: the orchestrator scales by adding replicas

threads: 8              # the in-process serving pool: UDP readers, and a TCP pool when asked for

max_connections: 200    # the proxy's fan-in bound for THIS replica, per accepted connection

protocol_settings:
  tcp:
    threads: 8          # opt in to a bounded TCP handler pool on this replica
```

Here `processes: 1` is the point. The replica forks nothing, so its memory is a single process the orchestrator can restart on its own schedule, and a rolling restart touches one replica at a time: the proxy drains a replica's traffic (stop routing to it), the replica's in-flight work finishes, and only then does it exit. Because a restart is per replica, scaling is a matter of replica count and the per-replica knobs above, never of the worker count.

### Self-contained device

A device with no orchestrator and no proxy has to supervise its own concurrency. That is what the cluster master is for:

```yaml
port: 5683
protocols: [udp, tcp]

processes: 4            # the device forks 4 supervised workers, each serving every transport

threads: 2              # reader threads per worker process

protocol_settings:
  tcp:
    threads: 2          # a small bounded TCP pool per worker
```

`processes: 4` forks four children and the master reaps and replaces each one that dies, one-for-one, so a crashed worker does not take the service down. Each child serves BOTH transports, because the master hands every child all of the service's sockets. There is nothing above the master: no proxy, no orchestrator, so the device's own supervision is the whole safety net.

### Sizing for many devices

The raw capacity of a service is `processes x per-process concurrency`, where the per-process concurrency is `threads` for UDP and, for TCP, either the thread-per-connection model (bounded instead by `max_connections`) or the handler pool when `protocol_settings[:tcp][:threads]` is written:

```text
UDP capacity  = processes x threads
TCP capacity  = processes x max_connections        # thread-per-connection shape
TCP capacity  = processes x protocol_settings[:tcp][:threads]   # pooled shape, bounded by max_connections too
```

So four workers with `threads: 2` give eight concurrent UDP handlers; four workers with `max_connections: 200` give an admitted-connection ceiling of `4 x 200 = 800`, counted per worker (`tcp.rb:404-419`), never globally. Pick the worker count first (how many process failures you can tolerate and how much memory you have), then size the per-process concurrency to the device's connection and datagram load.

A rolling restart of one replica behind a proxy is bounded by the numbers above. The orchestrator stops routing to the replica, then it stops the process: the process stops accepting, finishes in-flight work inside the deadline it declared (`POOL_JOIN_TIMEOUT` for a TCP handler, `DRAIN_DEADLINE` for datagram readers, both `1.0` s today - `tcp.rb:22`, `udp_worker.rb:20`), and the master's batch deadline of `2.0` s is strictly greater, so nothing is cut mid-flight (`cluster.rb:42`). Budget the restart at the batch deadline of `2.0` s per stopping replica, and give the proxy a drain window at least that long before it stops sending traffic. Measured per replica: a stopped child exits at `0.3073` s for an exchange that finishes inside the deadline and at `1.0975` s for a handler that never releases, both inside the `2.0` s batch (`.omo/evidence/task-13-verification-unified-cluster.txt`).

---

## Block-Wise Transfer Configuration

A CoAP datagram is small, so a body or a response that doesn't fit in one has to travel as a numbered sequence of blocks (RFC 7959). Takagi handles that for you: the `BlockWise` middleware slices large responses (Block2) and reassembles large requests (Block1), and both directions stay invisible to your route handlers. The settings below bound how much memory and time that work may take.

### Settings

| Setting | YAML Key | Default | Description |
|---------|----------|---------|-------------|
| **Enabled** | `block_wise.enabled` | true | Turn block-wise transfer on or off |
| **Block size (SZX)** | `block_wise.szx` | 6 | Block size exponent, `0` to `6` |
| **Max assembled bytes** | `block_wise.max_assembled_bytes` | 1048576 | Cap on one reassembled request body (1 MiB) |
| **Assembly TTL** | `block_wise.assembly_ttl` | 30 | Seconds an idle request assembly survives |
| **Max concurrent assemblies** | `block_wise.max_concurrent_assemblies` | 64 | Cap on in-flight request assemblies |

### What Each Setting Bounds

**`szx`** picks the block size. The size in bytes is `2 ** (szx + 4)`, so `0` gives 16-byte blocks, `2` gives 64, and the default `6` gives 1024 bytes, the largest size RFC 7959 allows. A client may ask for a smaller size, and the server never sends a larger block than the client requested. Values outside `0` to `6` are rejected at load time.

**`max_assembled_bytes`** caps a single request body rebuilt from Block1 pieces. When the accumulated bytes go past the cap, the server drops the assembly and answers `4.13 Request Entity Too Large`, advertising the limit in a Size1 option.

**`assembly_ttl`** is the idle timeout, in seconds, for a request assembly. A transfer that goes quiet for longer than this is discarded, so a half-finished upload can't pin memory forever.

**`max_concurrent_assemblies`** bounds the number of request assemblies held at once. When the table is full, the least recently used assembly is evicted to make room, which keeps a burst of large uploads from growing the table without limit.

**`enabled`** is `true` by default, so large payloads work out of the box. Set it to `false` to turn the middleware off, as shown below.

### Example

```yaml
block_wise:
  enabled: true
  szx: 6                 # 1024-byte blocks
  max_assembled_bytes: 1048576  # 1 MiB per request body
  assembly_ttl: 30       # seconds
  max_concurrent_assemblies: 64
```

For a memory-constrained device, lower the block size and the caps:

```yaml
block_wise:
  szx: 4                 # 256-byte blocks
  max_assembled_bytes: 65536
  assembly_ttl: 10
  max_concurrent_assemblies: 8
```

### Disabling Block-Wise Transfer

Set `enabled: false` in `takagi.yml`:

```yaml
block_wise:
  enabled: false
```

Or turn it off from code before the server starts:

```ruby
Takagi.config.block_wise.enabled = false
```

When it's off, responses that exceed one datagram are no longer sliced and large request bodies are no longer reassembled. Messages that already fit in a single block behave the same either way.

### Known Limitations

Two limits come from the current implementation. Neither has a built-in fix yet, so plan around them.

**Request assembly state is per-process.** The middleware keeps its Block1 table in memory, in the process that handles the request, keyed by the request token and path; every forked worker has its own table and nothing is shared between them (`lib/takagi/middleware/block_wise.rb:167-173`, the table at `:168`, the key at `:31-33`, and a block with no assembly for its key is answered `4.08 Request Entity Incomplete` at `:45,358`). The exposure differs by transport:

- **UDP workers:** with more than one forked UDP worker (`processes > 1`) the blocks of one upload can land on different workers, and the worker that sees a block without its predecessors answers `4.08`. Run a single UDP process for reliable large uploads, or supply shared storage of your own.
- **TCP workers:** the exposure is narrower, because a worker owns a connection for that connection's whole lifetime - one handler per accepted socket (`tcp.rb:273-277`) looping on it to the end (`:422`) - so the blocks a client sends on one connection always meet the same worker's table. Only a transfer whose blocks arrive on DIFFERENT connections is split across workers, and a block that finds no assembly in its new worker is answered `4.08`.

**The assembly key has no peer address.** An assembly is keyed by the request token and the URI path, and `Takagi::Message::Inbound` carries no peer accessor today, so the peer can't be part of the key. Two different peers that happen to use the same token on the same path would share one buffer. In practice block-wise clients send a token (RFC 7959 §2.5), which keeps the keys apart.

---

## Proxy Configuration

A proxy sits in front of one or more backends and forwards each request to the one that owns the requested URI namespace. The device talks to the proxy as if it were a single server; the proxy resolves the path and places the request on the outbound hop.

### Settings

| Setting | YAML Key | Default | Description |
|---------|----------|---------|-------------|
| **Enabled** | `proxy.enabled` | false | Turn the proxy on or off |
| **Routes** | `proxy.routes` | [] | Prefix-to-backend route list |
| **Names** | `proxy.names` | [] | Every name, alias and numeric address the proxy answers to |
| **Discovery** | `proxy.discovery` | `:local` | `:aggregate` merges backend `/.well-known/core`, `:local` answers with proxy routes only |
| **Forward** | `proxy.forward` | `:deny` | `:deny` refuses every forward-proxy request; `:configured` serves only when the authority matches a configured route |

### Route table

Each route has a `prefix`, a backend `host` and `port`, and an optional `outbound` transport:

```yaml
proxy:
  enabled: true
  routes:
    - prefix: /sensors
      host: 192.168.1.10
      port: 5683
    - prefix: /management
      host: 192.168.1.11
      port: 5683
      outbound: tcp
  names:
    - proxy.example.com
    - 192.168.1.1
  discovery: aggregate
  forward: configured
```

**Prefix matching is longest-prefix.** A request for `/sensors/temperature` matches `/sensors` and the relative path `/temperature` is forwarded to that backend. A request for `/sensors` matches the same route with an empty relative path. A request for `/unknown` matches no route and is answered by the proxy's own routes locally.

**Two routes cannot claim the same prefix.** The boot fails with a raise naming the duplicate prefix.

**A route pointing at the proxy's own names is rejected.** The proxy recognizes its own names to prevent request loops (RFC 7252 §5.10.2).

### Transport override

The default outbound transport is the same as the inbound one: a UDP client gets a UDP hop. A route can override this:

```yaml
proxy:
  routes:
    - prefix: /sensors
      host: 192.168.1.10
      port: 5683
      outbound: tcp    # UDP client -> TCP backend, response back on UDP
```

### Names list

The `names` list holds every host, alias and numeric address the proxy answers to. A request whose authority matches any of these is treated as local and answered by the proxy's own routes, never forwarded. This prevents request loops (RFC 7252 §5.7.2).

### Discovery modes

- **`discovery: local`** — the proxy answers `/.well-known/core` with its own mounted routes only.
- **`discovery: aggregate`** — the proxy asks every configured backend for its own `/.well-known/core`, merges the answers under each route's prefix, deduplicates identical entries, and returns the combined document. If a backend is unreachable, the answer still contains the reachable ones; the unreachable backend is logged, not surfaced to the client.

### Refusal and failure codes

The proxy answers with the standard CoAP proxy codes:

| Code | When it appears |
|------|----------------|
| **4.02 Bad Option** | The inbound request carries an unrecognized **Unsafe** option (RFC 7252 §5.7.1). An unknown **Safe** option is forwarded untouched. |
| **5.02 Bad Gateway** | The backend's response cannot be parsed, or carries an unrecognized **Unsafe** option in the response. |
| **5.04 Gateway Timeout** | The backend does not answer within the proxy's timeout. |
| **5.05 Proxying Not Supported** | A forward-proxy request (Proxy-Uri or Proxy-Scheme) arrives and the proxy is unwilling or unable to serve it — either `forward: deny` (the default) or `forward: configured` with an authority that matches no route. |

### Limitations

The proxy is a stateless forwarder. The following are explicitly not supported:

1. **No cache.** The proxy does not cache responses. Every request is forwarded to the backend.
2. **Observe is not relayed.** A subscription is not carried across the proxy. The proxy forwards an Observe request as a plain GET, returns one response to the client, and cancels the observation it opened at the backend.
3. **Block-wise passes through without reassembly.** Block1 and Block2 options are forwarded untouched. The proxy never reassembles a payload and never re-blocks.
4. **Reliability and assembly are per hop.** The proxy parses and re-originates messages for each leg: a new Message ID and a new Token on every outbound hop. Message identity is never reused across hops.
5. **No HTTP-CoAP translation and no DTLS.** The proxy is CoAP-to-CoAP only. HTTP-CoAP cross-proxying and coaps are not supported.

### Example: proxy plus two backends

```yaml
port: 5683
protocols: [udp, tcp]

proxy:
  enabled: true
  routes:
    - prefix: /sensors
      host: 192.168.1.10
      port: 5683
    - prefix: /management
      host: 192.168.1.11
      port: 5683
      outbound: tcp
  names:
    - proxy.example.com
    - 192.168.1.1
  discovery: aggregate
  forward: configured
```

Load it:

```ruby
Takagi.config.load_file('proxy.yml')
```

---

## Environment Variables Reference

### EventBus

```bash
# Worker pool
export EVENTBUS_RACTORS=10

# State cache (LRUCache)
export EVENTBUS_STATE_SIZE=1000
export EVENTBUS_STATE_TTL=3600

# Observer cleanup
export EVENTBUS_CLEANUP_INTERVAL=60
export EVENTBUS_MAX_OBSERVER_AGE=600
```

**Note:** Message buffering can only be enabled via YAML or programmatic API, not ENV variables.

---

## Examples

### Example 1: Local Development

```yaml
# dev.yml
port: 5683
threads: 2

event_bus:
  ractors: 5
  state_cache_size: 100
  message_buffering_enabled: false  # Fast, no buffering needed

custom:
  environment: development
  debug: true
```

```ruby
Takagi.config.load_file('dev.yml')
```

### Example 2: Production IoT Network

```yaml
# production.yml
port: 5683
threads: 8
processes: 2

event_bus:
  ractors: 20
  state_cache_size: 10000
  state_cache_ttl: 7200

  # Critical: Enable buffering for reliability
  message_buffering_enabled: true
  message_buffer_max_messages: 500
  message_buffer_ttl: 900  # 15 minutes

observability:
  backends:
    - prometheus

custom:
  environment: production
  max_devices: 1000
  alert_threshold: 100
```

```ruby
Takagi.config.load_file('production.yml')
```

### Example 3: Testing

```ruby
# test_helper.rb
Takagi.config.event_bus.ractors = 2
Takagi.config.event_bus.state_cache_size = 10
Takagi.config.event_bus.message_buffering_enabled = false
```

### Example 4: Environment-Specific Configuration

```ruby
# config/initializer.rb
env = ENV['RACK_ENV'] || 'development'
config_file = "config/#{env}.yml"

if File.exist?(config_file)
  Takagi.config.load_file(config_file)
else
  puts "Warning: Config file #{config_file} not found, using defaults"
end

# Enable message buffering for production only
if env == 'production'
  Takagi::EventBus.enable_message_buffering(
    max_messages: 500,
    ttl: 900
  )
end
```

### Example 5: Docker Environment

```dockerfile
# Dockerfile
ENV EVENTBUS_RACTORS=20
ENV EVENTBUS_STATE_SIZE=10000
ENV EVENTBUS_STATE_TTL=7200

COPY config/production.yml /app/takagi.yml
```

```yaml
# config/production.yml
port: 5683
threads: 8

event_bus:
  # ENV variables will override these if set
  ractors: 10
  state_cache_size: 5000

  # Must be in YAML (not supported via ENV)
  message_buffering_enabled: true
  message_buffer_max_messages: 500
  message_buffer_ttl: 900
```

---

## Configuration Best Practices

### 1. Use YAML for Complex Configuration

✅ **Good:**
```yaml
event_bus:
  ractors: 10
  message_buffering_enabled: true
  message_buffer_max_messages: 100
```

❌ **Avoid:** Long ENV variable lists

### 2. Environment-Specific Files

```
config/
  development.yml
  test.yml
  staging.yml
  production.yml
```

### 3. Sensitive Data

**Never commit secrets to YAML files!**

```yaml
# Use ENV for secrets
custom:
  api_key: <%= ENV['API_KEY'] %>  # ERB interpolation
  database_url: <%= ENV['DATABASE_URL'] %>
```

Or use programmatic configuration:

```ruby
Takagi.config[:api_key] = ENV['API_KEY']
```

### 4. Validate Configuration

```ruby
# Validate after loading
config = Takagi.config.event_bus

if config.message_buffering_enabled
  if config.message_buffer_max_messages < 10
    warn "Warning: Buffer size too small, increasing to 50"
    config.message_buffer_max_messages = 50
  end
end
```

### 5. Document Custom Settings

```yaml
custom:
  # Device management
  max_devices: 100          # Maximum concurrent devices
  device_timeout: 30        # Seconds before device marked offline

  # Alert thresholds
  alert_threshold: 100      # Number of alerts before escalation
  alert_cooldown: 300       # Seconds between alert emails
```

---

## Troubleshooting

### Configuration Not Loading

```ruby
# Debug configuration loading
begin
  Takagi.config.load_file('takagi.yml')
  puts "Config loaded successfully"
  puts "EventBus ractors: #{Takagi.config.event_bus.ractors}"
rescue StandardError => e
  puts "Config load error: #{e.message}"
  puts "Using defaults"
end
```

### ENV Variables Not Working

```ruby
# Verify ENV priority
puts "ENV: #{ENV['EVENTBUS_RACTORS']}"
puts "Config: #{Takagi.config.event_bus.ractors}"
puts "Actual: #{Takagi::EventBus.instance_variable_get(:@ractor_pool).size}"
```

### Message Buffering Not Enabled

```ruby
# Check configuration
config = Takagi.config.event_bus
puts "Buffering enabled: #{config.message_buffering_enabled}"
puts "Message store: #{Takagi::EventBus.message_store.inspect}"

# Enable manually if needed
if Takagi::EventBus.message_store.nil?
  Takagi::EventBus.enable_message_buffering
end
```

---

## See Also

- [EventBus Documentation](examples/eventbus_example.rb)
- [Example Configuration](examples/takagi.yml)
- [Message Buffering Guide](lib/takagi/event_bus/message_buffer.rb)