# Menu Bar and Agent Diagnostics

## Goal

AgentInjectionIII should make its runtime state visible to both a developer and an AI agent.

The feature has two user-facing outcomes:

1. A macOS menu bar item shows whether injectiond is reachable, which runtime targets are connected, whether the trace bridge is connected/active, and the most recent failure.
2. A single agent-facing diagnostics API returns enough state and history to diagnose failures across the entire injection path, not only connection failures.

The diagnostics surface is intentionally broader than networking. It covers daemon state, runtime discovery/handshake, compiler recovery, compile/link/injection lifecycle, trace bridge state, and the most recent structured error.

The menu also owns the human-triggered InjectionIII-style workflow: an FSEvents watcher in `injectiond` records pending source changes, while **Control + -** or **Inject Changed Files** explicitly triggers injection. Saving alone never injects.

## Design principles

- **One source of truth.** The menu bar, CLI, and MCP adapter all read the same Unix-domain-socket control plane exposed by injectiond.
- **Shared pending queue.** Human hotkey injection and Agent/MCP explicit injection reconcile against the same pending source store, preventing duplicate reinjection.
- **Keep injection logic in the daemon.** The menu app may own the daemon process lifecycle, but compilation, runtime transport, injection, tracing, and diagnostics remain in `injectiond`.
- **Non-consuming diagnostics.** Troubleshooting history must still be available after a failure. The diagnostics API therefore snapshots logs/events without draining them.
- **Backward compatibility.** Existing `logs`, `events`, `doctor`, `status`, and MCP tools remain available.
- **Structured first, raw logs retained.** Agent diagnostics combine structured state with recent raw daemon/runtime messages.
- **Safe LAN trace handling.** A trace bridge must send a versioned hello before registration, and a second connection must not replace an active bridge.

## Architecture

```text
                         +----------------------+
                         | AgentInjectionIII.app|
                         | MenuBarExtra + daemon|
                         | lifecycle management |
                         +----------+-----------+
                                    |
                                    | starts injectiond --enable-devices
                                    | ControlRequest / Unix socket
                                    v
Agent -> MCP server ----------> injectiond <---------- injectionctl
                                   |
                    +--------------+--------------+
                    |                             |
                    v                             v
          InjectionNext runtime            AgentTraceServer
              TCP :8887                       TCP :8888
                    |                             |
                    +--------------+--------------+
                                   |
                         shared AgentLogStore
                                   |
                 +-----------------+------------------+
                 |                 |                  |
                 v                 v                  v
              status           lifecycle          diagnostics
                               events               snapshot
```

## Diagnostics API

A new `diagnostics` control action returns a `DiagnosticsResult`.

The result contains:

- backend status
- connected runtime targets
- trace bridge status
- compiler interception / command-source state
- doctor report
- recent non-consuming logs
- recent non-consuming injection lifecycle events
- last structured error

This means an agent can answer questions such as:

- Did the device discover/connect to the Mac?
- Was the runtime handshake rejected?
- Is the app connected but the trace bridge missing?
- Was a compile command recovered?
- Did compilation fail, and with which compiler diagnostics?
- Did linking succeed but runtime loading fail?
- Which target was selected?
- What was the last known injection error?

### Control request

```json
{
  "action": "diagnostics",
  "limit": 200
}
```

### MCP tool

`get_diagnostics(limit?)` forwards to the same control action. It is the preferred first troubleshooting call when injection is not behaving as expected.

## Existing event sources

The implementation deliberately reuses the existing stores instead of introducing a parallel logging subsystem:

- `AgentLogStore`: runtime/daemon transport and informational messages.
- `InjectionEventStore`: structured compile/link/injection lifecycle events.
- `LastErrorResult`: most recent structured control/compiler/injection error.
- `doctor`: environment/build-log/runtime readiness checks.
- `compilerState`: compiler interception and captured command source.
- `AgentTraceServer.status()`: trace bridge connectivity and active state.

`InjectionEventStore` gains a non-consuming snapshot accessor. Existing consuming `events` behavior is preserved.

## Shared log stream

injectiond creates one `AgentLogStore` and passes it to both:

- `InjectionNextRuntimeServer`
- `AgentTraceServer`

This lets `get_logs` and `get_diagnostics` include trace bridge lifecycle messages alongside runtime messages.

Trace messages include:

- listener started
- invalid/version-mismatched hello rejected
- active-bridge replacement rejected
- bridge connected
- bridge disconnected

Runtime connection validation continues to emit its existing accepted/rejected messages.

## Menu bar

A new SwiftPM executable product, `agent-injection-menu`, uses SwiftUI `MenuBarExtra` on macOS 13+.

It polls the daemon through `UnixSocketClient` and never talks directly to TCP runtime/trace ports.

The menu shows:

- daemon reachable/unreachable
- injection ready/listening state
- connected target count
- each target's platform, architecture, peer address, and local/device classification
- trace bridge connected/active
- latest structured error when present
- a short list of recent warning/error log entries

Suggested visual states:

```text
● Ready         daemon reachable + >=1 runtime target
◐ Listening     daemon reachable + no runtime target
! Issue         daemon reachable + recent structured error
○ Offline       Unix socket unavailable
```

The status item is informational; injection remains agent/CLI controlled.

## Compatibility

- Existing simulator behavior remains loopback-only unless `--enable-devices` is supplied.
- Existing MCP tools are unchanged.
- Existing CLI commands are unchanged; `injectionctl diagnostics [LIMIT]` is additive.
- Existing `events` remains consuming; diagnostics snapshots are non-consuming.
- Existing runtime protocol is unchanged.
- Trace bridge hello is versioned at protocol 1.

## Tests

Required coverage:

1. Trace server rejects invalid hello.
2. Trace server does not let a second connection replace an active bridge.
3. Trace server keeps frames received after hello in the same TCP read.
4. Diagnostics snapshot does not consume injection events.
5. Diagnostics response contains status, trace, compiler state, logs, events, doctor, and last error.
6. MCP syntax/tests include `get_diagnostics`.
7. Swift package builds the menu executable.

## Implementation order

1. Land trace-bridge validation fix on main.
2. Create `feat/menu-diagnostics-observability`.
3. Land this design document.
4. Add non-consuming diagnostics model/control action/backend API.
5. Share the log store with trace server and add trace lifecycle logs.
6. Add CLI and MCP diagnostics entry points.
7. Add the MenuBarExtra executable.
8. Add/extend tests and run CI.
