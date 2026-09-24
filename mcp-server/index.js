#!/usr/bin/env node

import {
  McpServer
} from "@modelcontextprotocol/sdk/server/mcp.js";
import {
  StdioServerTransport
} from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import fs from "node:fs/promises";

import {
  sendRequest
} from "./socket-client.js";

function asText(response) {
  return {
    content: [
      {
        type: "text",
        text: JSON.stringify(
          response,
          null,
          2
        )
      }
    ],
    isError: response?.ok === false
  };
}

async function call(
  action,
  params = {},
  timeoutMs = 15000
) {
  try {
    return asText(
      await sendRequest(
        action,
        params,
        timeoutMs
      )
    );
  } catch (error) {
    return {
      content: [
        {
          type: "text",
          text: `Error: ${error.message}`
        }
      ],
      isError: true
    };
  }
}

const server = new McpServer({
  name: "agent-injection",
  version: "0.1.0"
});

const target = z.string()
  .optional()
  .describe(
    "Optional runtime target id from list_targets"
  );

server.tool(
  "get_status",
  "Get injectiond and connected runtime status",
  { target },
  async ({ target }) =>
    call(
      "status",
      { target }
    )
);

server.tool(
  "list_targets",
  "List connected iOS runtime targets",
  {},
  async () =>
    call("targets")
);

server.tool(
  "doctor",
  "Run agentInjectionIII environment preflight; optionally validate one source file",
  {
    source: z.string()
      .optional()
      .describe(
        "Absolute source path to validate"
      )
  },
  async ({ source }) =>
    call(
      "doctor",
      { path: source },
      30000
    )
);

server.tool(
  "inject_sources",
  "Compile and hot-inject changed Swift/Objective-C sources into the running app",
  {
    files: z.array(z.string())
      .min(1)
      .describe(
        "Absolute source file paths"
      ),
    target
  },
  async ({ files, target }) =>
    call(
      "inject",
      {
        files,
        target
      },
      60000
    )
);

server.tool(
  "load_dylib",
  "Load an already-built injection dylib into the connected runtime",
  {
    path: z.string()
      .describe(
        "Absolute dylib path"
      ),
    target
  },
  async ({ path, target }) =>
    call(
      "load_dylib",
      {
        path,
        target
      },
      30000
    )
);

server.tool(
  "take_screenshot",
  "Capture a PNG screenshot of the connected client app",
  { target },
  async ({ target }) => {
    try {
      const response =
        await sendRequest(
          "screenshot",
          { target },
          20000
        );

      if (
        !response?.ok ||
        !response?.screenshot?.path
      ) {
        return asText(response);
      }

      const image = await fs.readFile(
        response.screenshot.path
      );

      return {
        content: [
          {
            type: "image",
            data: image.toString(
              "base64"
            ),
            mimeType:
              response.screenshot.mimeType ||
              "image/png"
          },
          {
            type: "text",
            text: JSON.stringify(
              response,
              null,
              2
            )
          }
        ]
      };
    } catch (error) {
      return {
        content: [
          {
            type: "text",
            text:
              `Error: ${error.message}`
          }
        ],
        isError: true
      };
    }
  }
);

server.tool(
  "enable_touch_capture",
  "Enable UIKit touch-event capture in the connected app",
  { target },
  async ({ target }) =>
    call(
      "touch_capture",
      { target }
    )
);

server.tool(
  "read_touch_events",
  "Read and consume captured UIKit touch events",
  { target },
  async ({ target }) =>
    call(
      "touch_read",
      { target }
    )
);

server.tool(
  "replay_touch_events",
  "Replay captured UIKit touch events in the connected app",
  {
    events: z.array(z.any())
      .describe(
        "Touch events returned by read_touch_events"
      ),
    target
  },
  async ({ events, target }) =>
    call(
      "touch_replay",
      {
        target,
        payload: JSON.stringify({
          events
        })
      },
      30000
    )
);

server.tool(
  "get_logs",
  "Read injectiond/runtime logs",
  {
    since: z.number()
      .optional()
      .describe(
        "Unix timestamp; return only later entries"
      ),
    limit: z.number()
      .int()
      .positive()
      .max(500)
      .optional()
  },
  async ({ since, limit }) =>
    call(
      "logs",
      {
        since,
        limit
      }
    )
);

server.tool(
  "clear_logs",
  "Clear buffered injectiond/runtime logs",
  {},
  async () =>
    call("clear_logs")
);

server.tool(
  "get_injection_events",
  "Read and consume structured injection lifecycle events",
  {
    limit: z.number()
      .int()
      .positive()
      .max(1000)
      .optional()
  },
  async ({ limit }) =>
    call(
      "events",
      { limit }
    )
);

server.tool(
  "clear_injection_events",
  "Clear structured injection lifecycle events",
  {},
  async () =>
    call("clear_events")
);

server.tool(
  "get_last_error",
  "Get the last compiler/injection error",
  {},
  async () =>
    call("get_last_error")
);

server.tool(
  "get_compiler_state",
  "Get Swift compiler interception and command-capture state",
  {},
  async () =>
    call("compiler_state")
);

server.tool(
  "set_compiler_interception",
  "Enable or disable Swift compiler interception/command capture",
  {
    enabled: z.boolean()
  },
  async ({ enabled }) =>
    call(
      "compiler_interception",
      { enabled },
      30000
    )
);

server.tool(
  "unhide_symbols",
  "Export hidden Swift default-argument symbols needed by some injections",
  {},
  async () =>
    call(
      "unhide_symbols",
      {},
      30000
    )
);

server.tool(
  "prepare_swiftui_source",
  "Prepare one SwiftUI source file for injection",
  {
    path: z.string()
  },
  async ({ path }) =>
    call(
      "prepare_swiftui_source",
      { path },
      30000
    )
);

server.tool(
  "prepare_swiftui_project",
  "Prepare discovered SwiftUI sources in the project for injection",
  {},
  async () =>
    call(
      "prepare_swiftui_project",
      {},
      60000
    )
);

server.tool(
  "set_xcode_path",
  "Select the Xcode.app used by compiler/runtime tooling",
  {
    path: z.string()
  },
  async ({ path }) =>
    call(
      "set_xcode_path",
      { path }
    )
);

server.tool(
  "launch_xcode",
  "Launch the selected Xcode.app",
  {},
  async () =>
    call("launch_xcode")
);

server.tool(
  "set_runtime_environment",
  "Set or unset INJECTION_* runtime variables; null unsets a value",
  {
    values: z.record(
      z.string(),
      z.string().nullable()
    ),
    target
  },
  async ({ values, target }) =>
    call(
      "set_runtime_env",
      {
        environment: values,
        target
      }
    )
);

server.tool(
  "trace_start",
  "Start method-call tracing for the app",
  {
    filter: z.string()
      .optional()
  },
  async ({ filter }) =>
    call(
      "trace_start",
      { filter },
      30000
    )
);

server.tool(
  "trace_scope",
  "Start scoped tracing for frameworks/UIKit/SwiftUI/main app or a named framework/package",
  {
    scope: z.enum([
      "frameworks",
      "uikit",
      "swiftui",
      "main-all",
      "framework",
      "package"
    ]),
    name: z.string()
      .optional()
      .describe(
        "Required for framework/package scope"
      ),
    filter: z.string()
      .optional()
  },
  async ({
    scope,
    name,
    filter
  }) => {
    if (
      (
        scope === "framework" ||
        scope === "package"
      ) &&
      !name
    ) {
      return {
        content: [
          {
            type: "text",
            text:
              "Error: name is required for framework/package trace scope"
          }
        ],
        isError: true
      };
    }

    return call(
      "trace_scope",
      {
        scope,
        name,
        filter
      },
      30000
    );
  }
);

server.tool(
  "trace_read",
  "Read and consume buffered method-call trace events",
  {
    limit: z.number()
      .int()
      .positive()
      .max(5000)
      .optional()
  },
  async ({ limit }) =>
    call(
      "trace_read",
      { limit }
    )
);

server.tool(
  "trace_stop",
  "Stop method-call tracing",
  {},
  async () =>
    call(
      "trace_stop",
      {},
      30000
    )
);

server.tool(
  "profile_snapshot",
  "Get a method profile snapshot from AgentTraceBridge",
  {
    limit: z.number()
      .int()
      .positive()
      .max(5000)
      .optional()
  },
  async ({ limit }) =>
    call(
      "profile_snapshot",
      { limit },
      30000
    )
);

server.tool(
  "call_order",
  "Get runtime method call order for project-reordering analysis",
  {},
  async () =>
    call(
      "call_order",
      {},
      30000
    )
);

server.tool(
  "instances_start",
  "Start runtime instance/lifetime counting",
  {},
  async () =>
    call(
      "instances_start",
      {},
      30000
    )
);

server.tool(
  "instances_read",
  "Read current runtime instance counts",
  {},
  async () =>
    call(
      "instances_read",
      {},
      30000
    )
);

server.tool(
  "instances_stop",
  "Stop runtime instance/lifetime counting",
  {},
  async () =>
    call(
      "instances_stop",
      {},
      30000
    )
);

server.tool(
  "test_results",
  "Read injected XCTest/Swift Testing results observed by the runtime bridge",
  {
    limit: z.number()
      .int()
      .positive()
      .max(5000)
      .optional()
  },
  async ({ limit }) =>
    call(
      "test_results",
      { limit }
    )
);

server.tool(
  "clear_test_results",
  "Clear buffered injected test results",
  {},
  async () =>
    call("clear_test_results")
);

server.tool(
  "reorder_project",
  "Preview or apply PBXSourcesBuildPhase ordering based on observed call order",
  {
    apply: z.boolean()
      .default(false),
    project: z.string()
      .optional()
      .describe(
        "Optional .xcodeproj path"
      )
  },
  async ({
    apply,
    project
  }) =>
    call(
      "reorder_project",
      {
        enabled: apply,
        path: project
      },
      30000
    )
);

server.tool(
  "xprobe_search",
  "Search live objects exposed by the optional Xprobe bridge",
  {
    pattern: z.string()
      .optional()
  },
  async ({ pattern }) =>
    call(
      "xprobe_search",
      {
        filter: pattern
      },
      30000
    )
);

server.tool(
  "xprobe_inspect",
  "Inspect a live Xprobe object by id",
  {
    object_id: z.number()
      .int()
      .nonnegative()
  },
  async ({ object_id }) =>
    call(
      "xprobe_inspect",
      {
        objectID: object_id
      },
      30000
    )
);

server.tool(
  "eval_object",
  "Evaluate code against a live Xprobe object",
  {
    object_id: z.number()
      .int()
      .nonnegative(),
    code: z.string()
      .min(1)
  },
  async ({
    object_id,
    code
  }) =>
    call(
      "eval",
      {
        objectID: object_id,
        payload: code
      },
      30000
    )
);

const transport =
  new StdioServerTransport();

await server.connect(
  transport
);
