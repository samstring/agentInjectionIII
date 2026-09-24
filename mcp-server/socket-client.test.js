import test from "node:test";
import assert from "node:assert/strict";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import fs from "node:fs/promises";
import crypto from "node:crypto";
import { sendRequest } from "./socket-client.js";

async function withServer(handler, body) {
  const socket = path.join(
    os.tmpdir(),
    `agent-injection-mcp-${crypto.randomUUID()}.sock`
  );
  const server = net.createServer(handler);

  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(socket, resolve);
  });

  try {
    await body(socket);
  } finally {
    await new Promise((resolve) => {
      server.close(resolve);
    });
    await fs.rm(socket, { force: true });
  }
}

test(
  "sends newline-delimited ControlRequest and reads ControlResponse",
  async () => {
    await withServer(
      (client) => {
        let input = "";
        client.on("data", (chunk) => {
          input += chunk.toString("utf8");
          const newline = input.indexOf("\n");
          if (newline < 0) return;

          const request = JSON.parse(
            input.slice(0, newline)
          );

          assert.equal(
            request.action,
            "inject"
          );
          assert.deepEqual(
            request.files,
            ["/tmp/Foo.swift"]
          );
          assert.ok(request.id);
          assert.equal(
            "target" in request,
            false
          );

          client.end(
            JSON.stringify({
              id: request.id,
              ok: true,
              injections: []
            }) + "\n"
          );
        });
      },
      async (socket) => {
        const response = await sendRequest(
          "inject",
          {
            files: ["/tmp/Foo.swift"],
            target: undefined
          },
          1000,
          socket
        );

        assert.equal(
          response.ok,
          true
        );
        assert.deepEqual(
          response.injections,
          []
        );
      }
    );
  }
);
