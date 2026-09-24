#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOCKET="/tmp/agentInjectionIII-smoke-$.sock"
RUNTIME_PORT=$((20000 + ($ % 10000)))
TRACE_PORT=$((RUNTIME_PORT + 1))

cd "$ROOT"

swift build

"$ROOT/.build/debug/injectiond" \
  --socket "$SOCKET" \
  --runtime-port "$RUNTIME_PORT" \
  --trace-port "$TRACE_PORT" \
  >/tmp/agentInjectionIII-smoke.log 2>&1 &
DAEMON_PID=$!

cleanup() {
  kill "$DAEMON_PID" >/dev/null 2>&1 || true
  rm -f "$SOCKET"
}
trap cleanup EXIT

for _ in $(seq 1 50); do
  if [ -S "$SOCKET" ]; then
    break
  fi
  sleep 0.1
done

"$ROOT/.build/debug/injectionctl" --socket "$SOCKET" status
