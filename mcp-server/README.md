# agentInjectionIII MCP Server

This is a thin MCP adapter over the existing
`injectiond` Unix-domain-socket control plane.

It does not duplicate compilation or injection logic.

## 1. Start injectiond

From the project you want to work on:

```bash
swift run injectiond \
  --project /absolute/path/to/YourProject
```

The default control socket is:

```text
/tmp/agentInjectionIII.sock
```

## 2. Install the MCP server

```bash
cd mcp-server
npm install
npm test
npm start
```

To use another daemon socket:

```bash
AGENT_INJECTION_SOCKET=/tmp/custom.sock npm start
```

## 3. MCP client configuration

```json
{
  "mcpServers": {
    "agent-injection": {
      "command": "node",
      "args": [
        "/absolute/path/to/agentInjectionIII/mcp-server/index.js"
      ],
      "env": {
        "AGENT_INJECTION_SOCKET": "/tmp/agentInjectionIII.sock"
      }
    }
  }
}
```

## Architecture

```text
AI Agent
   |
   | MCP stdio
   v
agentInjectionIII MCP
   |
   | newline-delimited JSON
   | Unix domain socket
   v
injectiond
   |
   +--> BuildLogCompiler
   +--> InjectionNext runtime server
   +--> AgentTraceServer
            |
            v
      running iOS app
```

The MCP server sends the same `ControlRequest` messages as
`injectionctl`, so CLI and MCP behavior share the same backend.

## Exposed tool groups

### Injection

- `get_status`
- `list_targets`
- `doctor`
- `inject_sources`
- `load_dylib`

### UI verification

- `take_screenshot`
- `enable_touch_capture`
- `read_touch_events`
- `replay_touch_events`

### Diagnostics

- `get_logs`
- `clear_logs`
- `get_injection_events`
- `clear_injection_events`
- `get_last_error`
- `get_compiler_state`
- `set_compiler_interception`

### Runtime observation

- `trace_start`
- `trace_scope`
- `trace_read`
- `trace_stop`
- `profile_snapshot`
- `call_order`
- `instances_start`
- `instances_read`
- `instances_stop`
- `test_results`
- `clear_test_results`

### Project/runtime helpers

- `unhide_symbols`
- `prepare_swiftui_source`
- `prepare_swiftui_project`
- `set_xcode_path`
- `launch_xcode`
- `set_runtime_environment`
- `reorder_project`

### Optional introspection

- `xprobe_search`
- `xprobe_inspect`
- `eval_object`

## Typical Agent loop

```text
doctor
  -> edit source
  -> inject_sources
  -> get_injection_events
  -> replay_touch_events
  -> take_screenshot
  -> trace/profile/test_results
```

This gives an Agent an explicit control path instead of relying on
file-save watchers.
