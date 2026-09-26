# Menu Bar / Control Layer / Diagnostics Hardening

## Scope

This document records the long-term implementation requirements for the
`feature/menubar-multi-project-device` branch after multi-project and
multi-device routing was introduced.

The goal is to keep the user-facing Menu Bar small and predictable while
making project/runtime ownership, daemon lifetime and Agent troubleshooting
deterministic.

## 1. Compact Menu Bar

The Menu Bar window is an operational surface, not the primary diagnostics UI.

It should display only:

- global InjectionIII-style status light
- registered projects
- runtime/device sessions associated with each project
- per-runtime selection checkbox
- pending changed files and inject actions
- connection/manual injection error when one is active
- refresh and quit controls

The following diagnostic summary rows are intentionally removed from the
normal Menu Bar:

- Injection
- Doctor
- Connected runtimes
- Trace bridge
- Recent diagnostics

Diagnostics remain available through the CLI/control plane and unified log.

The Menu Bar window uses content-driven vertical sizing. It must not reserve
a large fixed vertical region when only one project/runtime is visible.

## 2. Runtime ownership must not move when projects are added

A connected Runtime belongs to the project it was built/run from.

Runtime metadata already supplied by InjectionNext is used for initial
association:

- `projectRoot`
- `executable`
- platform / architecture
- runtime target id

The initial matching algorithm prefers:

1. exact standardized project-root match
2. deepest registered project root containing the runtime root
3. when InjectionNext reports a workspace parent directory, a unique child
   registered project may be selected as a compatibility fallback

After the first successful association, the daemon pins:

```text
runtimeTargetID -> projectID
```

for the lifetime of that connected runtime session.

Registering another project must never cause an already-connected runtime to
move from Project A to Project B.

When the runtime disconnects, the assignment is pruned. A new runtime session
is matched again from its own metadata.

## 3. Internationalization

The Menu Bar has a lightweight localization layer.

Default product language:

```text
Simplified Chinese
```

English is supported as an alternate language.

Current selection sources:

```text
AGENT_INJECTION_LANGUAGE=en|zh
UserDefaults: AgentInjectionIII.language
```

If neither is configured, Simplified Chinese is used.

User-visible Menu Bar strings, project picker strings, status labels and
inject controls should go through this localization layer instead of embedding
English strings in SwiftUI views.

## 4. Exactly one Control Layer

There must be one AgentInjectionIII control layer per macOS user.

The control layer is the `injectiond` process containing:

```text
ControlRouter
MultiProjectInjectionBackend
InjectionNextRuntimeServer
AgentTraceServer
```

Menu Bar, CLI and Agent/Skill clients are clients of this control layer.

```text
Menu Bar -----\
Agent/Skill ---+--> injectionctl / Unix socket --> one injectiond
CLI ----------/
```

### Singleton mechanism

`injectiond` itself owns the singleton guarantee.

Lock file:

```text
~/Library/Application Support/AgentInjectionIII/injectiond.lock
```

The daemon acquires a non-blocking advisory `flock(LOCK_EX | LOCK_NB)`
before starting runtime, trace or control servers.

If another process already owns the lock, the new daemon exits without
starting a second Control Layer.

The lock file may contain PID/start metadata for diagnostics, but the file
contents are not the locking mechanism. The operating-system file lock is the
source of truth and is automatically released on normal exit, crash or
`kill -9`.

### Socket ownership

Only the process that owns the singleton lock may create/remove/bind the
control socket.

Menu Bar must not proactively unlink the control socket.

This prevents a second Menu Bar instance from deleting the socket belonging
to the active daemon.

Default control socket:

```text
/tmp/agentInjectionIII.sock
```

The singleton lock is intentionally independent of a custom socket argument;
changing `--socket` must not create a second Control Layer.

## 5. Unified diagnostic logging

All durable troubleshooting output is consolidated under one documented file:

```text
~/Library/Logs/AgentInjectionIII/diagnostics.log
```

The unified log contains:

- daemon lifecycle/startup
- control-layer singleton decisions
- runtime connect/disconnect/handshake information
- project/runtime routing information
- compiler/injection diagnostic messages
- injection lifecycle events such as compiling/compiled/signing/injecting/
  injected/failed
- stdout/stderr emitted by the daemon and dependencies

The previous split `injectiond.log` location is deprecated and should be
removed by the Menu Bar when transitioning to the unified log.

### Retention policy

Connection and diagnostic logs are current-day only.

At daemon startup:

```text
if diagnostics.log exists
and its modification date is not today
    truncate it
then append today's logs
```

Same-day daemon restarts append to the existing file.

This intentionally favors a small, high-signal debugging context for an Agent
over long-term historical retention.

## 6. Agent troubleshooting workflow

The Agent-facing path is CLI + Skill.

Normal flow:

```text
Agent
  -> Skill
  -> injectionctl
  -> Unix control socket
  -> injectiond
```

The Skill should use a deterministic troubleshooting sequence.

### Daemon reachable

Start with:

```bash
injectionctl status
injectionctl diagnostics
injectionctl last-error
injectionctl events 100
injectionctl logs 200
```

Interpretation:

- `status`: daemon/runtime availability
- `diagnostics`: complete current snapshot
- `last-error`: most specific recent failure
- `events`: injection phase and failure boundary
- `logs`: recent structured runtime/compiler messages

### Daemon unreachable

The CLI provides a daemon-independent reader:

```bash
injectionctl diagnostic-log 200
```

This reads:

```text
~/Library/Logs/AgentInjectionIII/diagnostics.log
```

without connecting to `injectiond`.

This is the final fallback for:

- daemon startup failure
- socket bind/connect failure
- singleton conflict
- runtime/trace server startup failure
- crash before the control socket becomes available

The Skill should prefer `diagnostic-log` rather than shell-specific
`tail` commands so the troubleshooting interface stays stable.

## 7. Multi-project / multi-device invariants

The changes above must preserve these invariants:

1. one daemon / one Control Layer per user
2. many independent project sessions inside that daemon
3. one shared runtime listener
4. each runtime is associated with exactly one project or remains unmatched
5. adding a project cannot steal an existing runtime session
6. one project may have multiple runtime devices
7. device checkbox selection controls injection targets, not project ownership
8. project pending sources remain isolated by project
9. injected acknowledgement remains per runtime
10. legacy single-project InjectionIII/InjectionNext behavior remains supported

## 8. Validation requirements

Before merging this branch, CI/manual validation should cover:

- Swift build
- Swift unit tests
- Menu Bar app build
- existing InjectionIII compatibility smoke
- multi-project routing
- runtime ownership remains stable after adding a project
- singleton lock rejects a second daemon
- current-day unified log appends
- previous-day unified log is truncated
- `injectionctl diagnostic-log` works with daemon unavailable
- simulator hot-reload smoke
- single-project flow remains unchanged
