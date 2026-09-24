import net from "node:net";
import crypto from "node:crypto";

export const CONTROL_SOCKET =
  process.env.AGENT_INJECTION_SOCKET ||
  "/tmp/agentInjectionIII.sock";

function compact(object) {
  return Object.fromEntries(
    Object.entries(object).filter(
      ([, value]) => value !== undefined
    )
  );
}

export function sendRequest(
  action,
  params = {},
  timeoutMs = 15000,
  socketPath = CONTROL_SOCKET
) {
  return new Promise((resolve, reject) => {
    const client = new net.Socket();
    const id = crypto.randomUUID();
    let data = "";
    let settled = false;

    const finish = (error, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      client.destroy();
      error ? reject(error) : resolve(value);
    };

    const timer = setTimeout(() => {
      finish(
        new Error(
          `Timed out waiting for injectiond at ${socketPath}`
        )
      );
    }, timeoutMs);

    client.connect(socketPath, () => {
      client.write(
        JSON.stringify(
          compact({ id, action, ...params })
        ) + "\n"
      );
    });

    client.on("data", (chunk) => {
      data += chunk.toString("utf8");
      const newline = data.indexOf("\n");
      if (newline < 0) return;

      try {
        finish(
          null,
          JSON.parse(data.slice(0, newline))
        );
      } catch (error) {
        finish(
          new Error(
            `Invalid JSON response from injectiond: ${error.message}`
          )
        );
      }
    });

    client.on("end", () => {
      if (!settled && data.trim()) {
        try {
          finish(null, JSON.parse(data.trim()));
        } catch (error) {
          finish(
            new Error(
              `Invalid JSON response from injectiond: ${error.message}`
            )
          );
        }
      } else if (!settled) {
        finish(
          new Error(
            "injectiond closed the socket without a response"
          )
        );
      }
    });

    client.on("error", (error) => {
      const suffix = [
        "ENOENT",
        "ECONNREFUSED"
      ].includes(error.code)
        ? " Make sure injectiond is running and " +
          "AGENT_INJECTION_SOCKET points to its socket."
        : "";

      finish(
        new Error(
          `${error.message}.${suffix}`
        )
      );
    });
  });
}
