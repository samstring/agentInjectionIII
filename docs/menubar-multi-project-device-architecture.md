# Multi-Project / Multi-Device Menu Bar Architecture

## Goal

Support multiple independent top-level project directories at the same time, with one daemon and one runtime listener. Each project owns its watcher/compiler/pending-change state, while runtime sessions are routed to projects by metadata already emitted by InjectionNext.

Example:

```text
/Users/me/Projects/AppA  <-> ProjectSession A <-> iPhone A
/Users/me/Work/AppB      <-> ProjectSession B <-> iPhone B
```

The design must preserve the existing one-project CLI/daemon flow and regular InjectionIII/InjectionNext behavior.

## Principles

1. Do not duplicate InjectionIII source-selection/compiler logic in the Menu Bar.
2. Keep one injectiond process and one runtime TCP/UDP discovery endpoint.
3. Give every project its own watcher, BuildLogCompiler, pending-source store and diagnostics state.
4. Route runtime sessions to projects using InjectionNext's existing `projectRoot` and `executable` responses. Do not change the upstream wire protocol for this feature.
5. Explicit target IDs always win. Automatic routing is only used when no target is supplied.
6. A source path is routed to the deepest registered project root that contains it.
7. Legacy single-project requests continue to work without a project id.

## Runtime identity

InjectionNext already emits:

- platform / architecture
- temporary path
- projectRoot
- executable

AgentInjectionIII currently logs `projectRoot` and `executable` and discards them. The runtime client will retain these fields and expose them through `RuntimeTarget`.

A registered project matches a runtime when the standardized runtime project root equals the registered root, or one path contains the other. This supports workspace roots and project subdirectories without coupling identity to IP/device name.

## Core model

```text
InjectionNextRuntimeServer
          |
          +-- RuntimeTarget A (projectRoot=/Projects/AppA)
          +-- RuntimeTarget B (projectRoot=/Work/AppB)
          |
MultiProjectInjectionBackend
          |
          +-- ProjectSession A
          |      root=/Projects/AppA
          |      InjectionNextRuntimeBackend
          |      ProjectFileWatcher
          |      BuildLogCompiler
          |      PendingSourceStore
          |
          +-- ProjectSession B
                 root=/Work/AppB
                 InjectionNextRuntimeBackend
                 ProjectFileWatcher
                 BuildLogCompiler
                 PendingSourceStore
```

## Project identity

Each registered root receives a deterministic local project id derived from its standardized path. The id is only a daemon/control-plane key. Runtime routing remains based on runtime-reported projectRoot so upstream InjectionNext does not need modification.

## Control protocol

Add:

- `projects`
- `project_add`
- `project_remove`
- optional `projectID` on ControlRequest

Project-aware routing applies to:

- pending_changes
- inject_pending
- inject
- doctor
- diagnostics
- targets

Without `projectID`:

- one registered project -> exact legacy behavior
- source-based injection -> route each file by containing root
- inject_pending -> process every registered project that has pending files
- targets -> all runtime targets

## Menu Bar

Menu Bar persists an array of project roots instead of one root. It starts injectiond once, registers all persisted projects, and displays:

- Projects
  - root
  - pending file count
  - matched runtime targets
- Devices/runtime sessions under the matching project
- Pending changes grouped by project
- Inject changed files globally or per project
- Ctrl+- injects pending changes for every registered project; each project is delivered only to matching runtime sessions.

## Compatibility

- `injectiond --project ROOT` remains valid.
- Repeated `--project ROOT` is accepted.
- Existing clients that omit `projectID` still decode and work.
- Existing RuntimeTarget fields remain source-compatible; new identity fields are optional.
- InjectionNext wire values are unchanged.
- Single-project CI smoke remains required.

## Implementation stages

1. Persist runtime projectRoot/executable in RuntimeTarget.
2. Add protocol project/session DTOs and project-aware control requests.
3. Add MultiProjectInjectionBackend that owns independent InjectionNextRuntimeBackend instances sharing runtime/trace servers.
4. Teach ControlRouter to route project-aware actions.
5. Allow repeated --project in injectiond.
6. Refactor Menu Bar persistence/UI to multiple project roots.
7. Add tests for source routing, runtime matching, protocol backward compatibility, and independent pending stores.
8. Run Swift tests and existing simulator smoke CI.


## Menu Bar device selection and InjectionIII-style state

Runtime-to-project association remains automatic. Device selection only controls which matching runtimes receive an injection when one project is running on multiple devices.

Selection rules:

- every matching runtime is selected by default
- users can deselect individual runtimes under a project
- deselection is persisted using a runtime fingerprint based on project, locality/address, executable, platform and architecture
- `Ctrl+-` respects the per-project selections
- an empty selected set never falls back to an unrelated runtime
- multi-target requests are sent as one project-scoped control request; partial failure re-queues the pending sources

The visual state follows InjectionIII's four-state model:

```text
Idle  -> gray   (no matching runtime)
Busy  -> orange (injection in progress)
OK    -> green  (runtime connected / last injection succeeded)
Error -> red    (injection or daemon error)
```

The state light is shown in the macOS Menu Bar label, the popover header, every project row and every runtime row. This mirrors InjectionIII's `Idle / Busy / OK / Error` status semantics while using native SwiftUI colors rather than copying InjectionIII image assets.


## Single control layer

`injectiond` is the only control-layer owner. It acquires a non-blocking per-user `flock` at:

```text
~/Library/Application Support/AgentInjectionIII/injectiond.lock
```

The lock is acquired before the runtime server, trace server, or Unix control socket are started. A second `injectiond` exits immediately if the lock is already held.

Menu Bar instances are connect-first clients and may attempt to spawn the daemon only when the control socket does not respond. The singleton lock resolves cold-start races. CLI + Skill never own the daemon lifecycle.

Only the lock owner may reach `UnixSocketServer.run()`, which performs stale control-socket cleanup before bind.

## Stable runtime ownership

Runtime-to-project routing uses runtime-reported `projectRoot` and `executable`, but the selected project is pinned for the lifetime of each runtime connection:

```text
runtime target id -> project id
```

Adding another project does not recompute or steal an already connected runtime. Assignments are discarded when the runtime disconnects or its project is removed.

This is especially important when InjectionNext reports `BUILD_WORKSPACE_DIRECTORY`, which can be a parent directory containing more than one registered project.

## Unified diagnostics

Persistent troubleshooting output is written to one file only:

```text
~/Library/Logs/AgentInjectionIII/diagnostics.log
```

The stream includes daemon lifecycle, runtime connection metadata, routing decisions, injection lifecycle events, errors, and raw stdout/stderr from the daemon.

On daemon startup, an existing log from a previous calendar day is truncated. Same-day daemon restarts append to the current file.

`injectionctl diagnostic-log [LIMIT]` reads this file without requiring a live daemon.

## Menu localization and sizing

The Menu Bar UI uses a localization layer with Simplified Chinese as the product default and English as an alternate language. English can currently be selected with:

```text
AGENT_INJECTION_LANGUAGE=en
```

or the `AgentInjectionIII.language` UserDefaults key.

The Menu Bar window sizes vertically to its actual content. Operational diagnostics (Doctor, total connected runtimes, Trace status, recent diagnostics) are intentionally not rendered in the normal Menu Bar UI; they remain available through CLI diagnostics and the unified log.
