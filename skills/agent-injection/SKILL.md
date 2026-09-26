# AgentInjectionIII Skill

## Purpose

Use the local `injectionctl` CLI to inspect and control the single AgentInjectionIII `injectiond` control layer.

Do not start another `injectiond` process from this skill.

## Control-layer rule

Always assume one daemon per macOS user:

```text
Agent / Skill
    ↓
injectionctl
    ↓
/tmp/agentInjectionIII.sock
    ↓
single injectiond
```

If the daemon is unavailable, report the failure and inspect the unified diagnostic log. Do not launch a replacement daemon yourself.

## Normal workflow

1. Check status.

```bash
injectionctl status
```

2. Inspect targets when device selection matters.

```bash
injectionctl targets
```

3. Validate a source when needed.

```bash
injectionctl doctor /absolute/path/File.swift
```

4. Inject the requested source.

```bash
injectionctl inject /absolute/path/File.swift
```

5. Verify all returned injection results have both:

```text
compiled = true
injected = true
```

## Troubleshooting workflow

If `injectionctl status` fails:

```bash
injectionctl diagnostic-log 300
```

This command does not require a running daemon.

If the daemon is reachable but the runtime is missing:

```bash
injectionctl targets
injectionctl diagnostics 100
injectionctl diagnostic-log 300
```

If compilation or hot reload fails:

```bash
injectionctl last-error
injectionctl events 100
injectionctl diagnostics 100
injectionctl diagnostic-log 300
```

Use event phases to identify the failure stage:

```text
changed
compiling
compiled
signing
injecting
injected
failed
```

## Unified log

Persistent diagnostics are stored only at:

```text
~/Library/Logs/AgentInjectionIII/diagnostics.log
```

The daemon keeps the current calendar day's log. On startup, if the existing log belongs to a previous day, it is cleared before new entries are written.

## Multi-project / multi-device rules

- A runtime is automatically associated with the project it reports through runtime project metadata.
- Once a connected runtime session is assigned to a project, adding another project must not steal that runtime.
- Explicit target IDs must belong to the requested project.
- Never route a source to an unrelated runtime as a fallback.
- Respect device selections made by the Menu Bar when operating through project-scoped pending injection.
