#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SMOKE_DIR="$REPO_ROOT/Examples/SimulatorSmokeApp"
SOURCE="$SMOKE_DIR/Sources/SmokeViewController.swift"
BUNDLE_ID="dev.agentinjection.smoke"

ARTIFACTS="${SMOKE_ARTIFACTS:-${RUNNER_TEMP:-$REPO_ROOT/.artifacts}/agentInjectionIII-smoke}"
DERIVED="${SMOKE_DERIVED_DATA:-${RUNNER_TEMP:-/tmp}/agentInjectionIII-smoke-derived}"
SOCKET="$ARTIFACTS/agentInjectionIII.sock"
DAEMON_LOG="$ARTIFACTS/injectiond.log"
BUILD_LOG="$ARTIFACTS/xcodebuild.log"
STATUS_JSON="$ARTIFACTS/status.json"
INJECT_JSON="$ARTIFACTS/inject.json"
SCREENSHOT_JSON="$ARTIFACTS/screenshot.json"
SCREENSHOT_PNG="$ARTIFACTS/after.png"
TOUCH_CAPTURE_JSON="$ARTIFACTS/touch-capture.json"
TOUCH_EVENTS_JSON="$ARTIFACTS/touch-events.json"
TOUCH_REPLAY_JSON="$ARTIFACTS/touch-replay.json"

mkdir -p "$ARTIFACTS"
rm -rf "$DERIVED"
rm -f "$SOCKET" "$DAEMON_LOG" "$BUILD_LOG" \
  "$STATUS_JSON" "$INJECT_JSON" "$SCREENSHOT_JSON" "$SCREENSHOT_PNG" \
  "$TOUCH_CAPTURE_JSON" "$TOUCH_EVENTS_JSON" "$TOUCH_REPLAY_JSON"

DAEMON_PID=""
UDID="${SMOKE_UDID:-}"
BOOTED_BY_SCRIPT=0
ORIGINAL_SOURCE="$ARTIFACTS/SmokeViewController.swift.original"

cp "$SOURCE" "$ORIGINAL_SOURCE"

cleanup() {
  status=$?

  cp "$ORIGINAL_SOURCE" "$SOURCE" 2>/dev/null || true

  if [ -n "$DAEMON_PID" ]; then
    kill "$DAEMON_PID" >/dev/null 2>&1 || true
    wait "$DAEMON_PID" >/dev/null 2>&1 || true
  fi

  rm -f "$SOCKET" >/dev/null 2>&1 || true

  if [ -n "$UDID" ]; then
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true

    if [ "$status" != "0" ]; then
      xcrun simctl spawn "$UDID" log show \
        --style compact \
        --last 5m \
        --predicate 'process == "SimulatorSmokeApp"' \
        > "$ARTIFACTS/simulator-app.log" 2>&1 || true
    fi

    if [ "$BOOTED_BY_SCRIPT" = "1" ]; then
      xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
    fi
  fi

  exit "$status"
}
trap cleanup EXIT INT TERM

select_simulator() {
  if [ -n "$UDID" ]; then
    return
  fi

  UDID="$(
    xcrun simctl list devices available -j |
      python3 -c '
import json, sys
data = json.load(sys.stdin)
for runtime, devices in data.get("devices", {}).items():
    if "iOS" not in runtime:
        continue
    for device in devices:
        if device.get("isAvailable") and device.get("name", "").startswith("iPhone"):
            print(device["udid"])
            raise SystemExit(0)
raise SystemExit(1)
'
  )"
}

simulator_state() {
  xcrun simctl list devices -j |
    python3 -c '
import json, sys
udid = sys.argv[1]
data = json.load(sys.stdin)
for devices in data.get("devices", {}).values():
    for device in devices:
        if device.get("udid") == udid:
            print(device.get("state", "Unknown"))
            raise SystemExit(0)
raise SystemExit(1)
' "$UDID"
}

ensure_cocoapods() {
  if command -v pod >/dev/null 2>&1 &&
     ruby -e "require 'xcodeproj'" >/dev/null 2>&1; then
    return
  fi

  echo "Installing CocoaPods for smoke test..."
  sudo gem install cocoapods -v 1.16.2 --no-document
}

json_assert_connected() {
  python3 - "$STATUS_JSON" <<'PY'
import json, sys

text = open(sys.argv[1]).read()
start = text.find("{")
if start < 0:
    raise SystemExit(1)
data, _ = json.JSONDecoder().raw_decode(text[start:])
connected = bool(
    data.get("ok")
    and data.get("status", {})
            .get("backend", {})
            .get("appConnected")
)
raise SystemExit(0 if connected else 1)
PY
}

json_assert_injected() {
  python3 - "$INJECT_JSON" <<'PY'
import json, sys

text = open(sys.argv[1]).read()
start = text.find("{")
if start < 0:
    raise SystemExit(1)
data, _ = json.JSONDecoder().raw_decode(text[start:])
items = data.get("injections") or []
ok = bool(
    data.get("ok")
    and items
    and all(item.get("compiled") and item.get("injected") for item in items)
)
if not ok:
    print(json.dumps(data, indent=2), file=sys.stderr)
raise SystemExit(0 if ok else 1)
PY
}

wait_for_marker() {
  expected="$1"
  marker="$2"

  for _ in $(seq 1 120); do
    if [ -f "$marker" ] &&
       [ "$(cat "$marker" 2>/dev/null || true)" = "$expected" ]; then
      return 0
    fi
    sleep 0.25
  done

  echo "Timed out waiting for marker '$expected' at $marker" >&2
  if [ -f "$marker" ]; then
    echo "Current marker: $(cat "$marker")" >&2
  fi
  return 1
}

echo "==> Build host tools"
cd "$REPO_ROOT"
swift build

DAEMON="$REPO_ROOT/.build/debug/injectiond"
CTL="$REPO_ROOT/.build/debug/injectionctl"

echo "==> Select and boot iOS Simulator"
select_simulator
echo "Using simulator: $UDID"

if [ "$(simulator_state)" != "Booted" ]; then
  BOOTED_BY_SCRIPT=1
  xcrun simctl boot "$UDID"
fi
xcrun simctl bootstatus "$UDID" -b

echo "==> Build local InjectionNext runtime (Simulator only)"
AGENT_INJECTION_SIMULATOR_ONLY=1 \
  bash "$REPO_ROOT/scripts/install-runtime.sh"

echo "==> Generate mixed ObjC/Swift Xcode project"
ensure_cocoapods
cd "$SMOKE_DIR"
ruby generate_project.rb

echo "==> Install CocoaPods"
export COCOAPODS_DISABLE_STATS=true
pod install --repo-update

echo "==> Build CocoaPods workspace"
set +e
xcodebuild \
  -workspace "$SMOKE_DIR/SimulatorSmokeApp.xcworkspace" \
  -scheme SimulatorSmokeApp \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "$DERIVED" \
  build 2>&1 | tee "$BUILD_LOG"
XCODE_STATUS=${PIPESTATUS[0]}
set -e

if [ "$XCODE_STATUS" != "0" ]; then
  echo "Smoke app build failed." >&2
  exit "$XCODE_STATUS"
fi

echo "==> Seed captured Swift frontend commands from xcodebuild output"
FRONTEND_LOG="$HOME/.agentInjectionIII/cache/frontend-commands.log"
mkdir -p "$(dirname "$FRONTEND_LOG")"
python3 - "$BUILD_LOG" "$FRONTEND_LOG" "$SMOKE_DIR" <<'PY'
from pathlib import Path
import sys

build_log = Path(sys.argv[1])
frontend_log = Path(sys.argv[2])
working_directory = sys.argv[3]

commands = []
for raw in build_log.read_text(errors="replace").splitlines():
    line = raw.strip()
    if "swift-frontend" not in line:
        continue
    if " -frontend " not in line or " -c " not in line:
        continue
    if "SmokeViewController.swift" not in line:
        continue
    start = line.find("/")
    if start < 0:
        continue
    command = line[start:]
    commands.append(f"{working_directory}\t{command}")

if not commands:
    raise SystemExit(
        "No Swift frontend compile command for SmokeViewController.swift "
        "was found in xcodebuild output."
    )

frontend_log.write_text("\n".join(commands) + "\n")
print(f"Captured {len(commands)} Swift frontend command(s) -> {frontend_log}")
PY

APP="$DERIVED/Build/Products/Debug-iphonesimulator/SimulatorSmokeApp.app"
if [ ! -d "$APP" ]; then
  echo "Built app not found: $APP" >&2
  exit 1
fi

if [ ! -d "$APP/iOSInjection.bundle" ]; then
  echo "Embedded iOSInjection.bundle not found in smoke app." >&2
  exit 1
fi

echo "==> Start injectiond"
cd "$REPO_ROOT"
"$DAEMON" \
  --socket "$SOCKET" \
  --project "$SMOKE_DIR" \
  --derived-data "$DERIVED" \
  >"$DAEMON_LOG" 2>&1 &
DAEMON_PID=$!

for _ in $(seq 1 80); do
  [ -S "$SOCKET" ] && break
  if ! kill -0 "$DAEMON_PID" >/dev/null 2>&1; then
    echo "injectiond exited before creating control socket." >&2
    cat "$DAEMON_LOG" >&2 || true
    exit 1
  fi
  sleep 0.25
done

if [ ! -S "$SOCKET" ]; then
  echo "Timed out waiting for injectiond socket." >&2
  cat "$DAEMON_LOG" >&2 || true
  exit 1
fi

echo "==> Install and launch mixed ObjC/Swift/CocoaPods app"
xcrun simctl uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl install "$UDID" "$APP"
xcrun simctl launch "$UDID" "$BUNDLE_ID"

echo "==> Wait for Injection runtime handshake"
connected=0
for _ in $(seq 1 120); do
  if "$CTL" --socket "$SOCKET" status >"$STATUS_JSON" 2>/dev/null &&
     json_assert_connected; then
    connected=1
    break
  fi
  sleep 0.25
done

if [ "$connected" != "1" ]; then
  echo "Injection runtime did not connect." >&2
  cat "$STATUS_JSON" >&2 2>/dev/null || true
  cat "$DAEMON_LOG" >&2 || true
  exit 1
fi

DATA_CONTAINER="$(
  xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data
)"
MARKER="$DATA_CONTAINER/Documents/agentInjection-smoke.txt"
TOUCH_TARGET="$DATA_CONTAINER/Documents/agentInjection-touch-target.json"
TOUCH_MARKER="$DATA_CONTAINER/Documents/agentInjection-touch.txt"

echo "==> Verify initial Swift behavior: BEFORE"
wait_for_marker "BEFORE" "$MARKER"

echo "==> Modify Swift source without rebuilding app"
python3 - "$SOURCE" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
old = '        "BEFORE"'
new = '        "AFTER"'
if old not in text:
    raise SystemExit("BEFORE marker source was not found")
path.write_text(text.replace(old, new, 1))
PY

echo "==> Inject changed Swift source"
"$CTL" --socket "$SOCKET" inject "$SOURCE" | tee "$INJECT_JSON"
json_assert_injected

echo "==> Verify running app changed without rebuild/relaunch: AFTER"
wait_for_marker "AFTER" "$MARKER"

echo "==> Verify InjectionNext screenshot command"
"$CTL" --socket "$SOCKET" screenshot "$SCREENSHOT_PNG" |
  tee "$SCREENSHOT_JSON"

python3 - "$SCREENSHOT_JSON" "$SCREENSHOT_PNG" <<'PY'
import json, os, sys

text = open(sys.argv[1]).read()
start = text.find("{")
if start < 0:
    raise SystemExit(1)
data, _ = json.JSONDecoder().raw_decode(text[start:])

path = sys.argv[2]
ok = bool(
    data.get("ok")
    and data.get("screenshot", {}).get("byteCount", 0) > 1000
    and os.path.isfile(path)
    and os.path.getsize(path) > 1000
)
if not ok:
    print(json.dumps(data, indent=2), file=sys.stderr)
raise SystemExit(0 if ok else 1)
PY

echo "==> Enable InjectionNext touch capture"
"$CTL" --socket "$SOCKET" touch capture |
  tee "$TOUCH_CAPTURE_JSON"

python3 - "$TOUCH_CAPTURE_JSON" <<'PY'
import json, sys

text = open(sys.argv[1]).read()
start = text.find("{")
if start < 0:
    raise SystemExit(1)
data, _ = json.JSONDecoder().raw_decode(text[start:])
ok = bool(
    data.get("ok")
    and data.get("touch", {}).get("target")
)
if not ok:
    print(json.dumps(data, indent=2), file=sys.stderr)
raise SystemExit(0 if ok else 1)
PY

echo "==> Wait for smoke app touch target coordinates"
for _ in $(seq 1 80); do
  if [ -s "$TOUCH_TARGET" ] &&
     python3 - "$TOUCH_TARGET" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
    ok = float(data["x"]) > 0 and float(data["y"]) > 0
except Exception:
    ok = False
raise SystemExit(0 if ok else 1)
PY
  then
    break
  fi
  sleep 0.25
done

if [ ! -s "$TOUCH_TARGET" ]; then
  echo "Touch target coordinates were not produced by the app." >&2
  exit 1
fi

rm -f "$TOUCH_MARKER"

echo "==> Build and replay a real UIKit touch sequence"
python3 - "$TOUCH_TARGET" "$TOUCH_EVENTS_JSON" <<'PY'
import json, sys

target = json.load(open(sys.argv[1]))
x = float(target["x"])
y = float(target["y"])

def event(time, phase):
    return {
        "time": time,
        "phase": phase,
        "touches": [
            {
                "id": 1,
                "x": x,
                "y": y,
                "phase": phase,
                "tapCount": 1,
            }
        ],
    }

payload = {
    "events": [
        event(1.0, "began"),
        event(1.08, "ended"),
    ]
}
with open(sys.argv[2], "w") as f:
    json.dump(payload, f)
PY

"$CTL" --socket "$SOCKET" touch replay "$TOUCH_EVENTS_JSON" |
  tee "$TOUCH_REPLAY_JSON"

python3 - "$TOUCH_REPLAY_JSON" <<'PY'
import json, sys

text = open(sys.argv[1]).read()
start = text.find("{")
if start < 0:
    raise SystemExit(1)
data, _ = json.JSONDecoder().raw_decode(text[start:])
ok = bool(
    data.get("ok")
    and data.get("touch", {}).get("target")
    and data.get("touch", {}).get("replayed") == 2
)
if not ok:
    print(json.dumps(data, indent=2), file=sys.stderr)
raise SystemExit(0 if ok else 1)
PY

echo "==> Verify replayed touch reached the live UIButton"
wait_for_marker "TOUCHED" "$TOUCH_MARKER"

echo
echo "Simulator smoke test passed:"
echo "  mixed ObjC + Swift: yes"
echo "  CocoaPods (Masonry): yes"
echo "  runtime handshake: yes"
echo "  Swift injection BEFORE -> AFTER: yes"
echo "  screenshot: $SCREENSHOT_PNG"
echo "  touch capture command: yes"
echo "  touch replay -> UIButton action: yes"
