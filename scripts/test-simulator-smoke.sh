#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SMOKE_DIR="$REPO_ROOT/Examples/SimulatorSmokeApp"
SOURCE="$SMOKE_DIR/Sources/SmokeViewController.swift"
BUNDLE_ID="dev.agentinjection.smoke"

FEATURE_PROJECT_COUNT="${SMOKE_FEATURE_PROJECT_COUNT:-6}"
SWIFT_FILLERS_PER_FEATURE="${SMOKE_SWIFT_FILLERS_PER_FEATURE:-160}"
OBJC_FILLERS_PER_FEATURE="${SMOKE_OBJC_FILLERS_PER_FEATURE:-48}"
MAIN_SWIFT_FILLERS="${SMOKE_MAIN_SWIFT_FILLERS:-160}"
MAIN_OBJC_FILLERS="${SMOKE_MAIN_OBJC_FILLERS:-80}"
export SMOKE_FEATURE_PROJECT_COUNT="$FEATURE_PROJECT_COUNT"
export SMOKE_SWIFT_FILLERS_PER_FEATURE="$SWIFT_FILLERS_PER_FEATURE"
export SMOKE_OBJC_FILLERS_PER_FEATURE="$OBJC_FILLERS_PER_FEATURE"
export SMOKE_MAIN_SWIFT_FILLERS="$MAIN_SWIFT_FILLERS"
export SMOKE_MAIN_OBJC_FILLERS="$MAIN_OBJC_FILLERS"

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
TRACE_START_JSON="$ARTIFACTS/trace-start.json"
TRACE_READ_JSON="$ARTIFACTS/trace-read.json"
TRACE_STOP_JSON="$ARTIFACTS/trace-stop.json"
PROFILE_JSON="$ARTIFACTS/profile.json"
CALL_ORDER_JSON="$ARTIFACTS/call-order.json"
INSTANCES_START_JSON="$ARTIFACTS/instances-start.json"
INSTANCES_READ_JSON="$ARTIFACTS/instances-read.json"
INSTANCES_STOP_JSON="$ARTIFACTS/instances-stop.json"

mkdir -p "$ARTIFACTS"
rm -rf "$DERIVED"
rm -f "$SOCKET" "$DAEMON_LOG" "$BUILD_LOG" \
  "$STATUS_JSON" "$INJECT_JSON" \
  "$SCREENSHOT_JSON" "$SCREENSHOT_PNG" \
  "$TOUCH_CAPTURE_JSON" "$TOUCH_EVENTS_JSON" "$TOUCH_REPLAY_JSON" \
  "$TRACE_START_JSON" "$TRACE_READ_JSON" "$TRACE_STOP_JSON" \
  "$PROFILE_JSON" "$CALL_ORDER_JSON" \
  "$INSTANCES_START_JSON" "$INSTANCES_READ_JSON" "$INSTANCES_STOP_JSON"
rm -f "$ARTIFACTS"/feature-*.json "$ARTIFACTS"/feature-*-xcodebuild.log

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
  json_path="${1:-$INJECT_JSON}"
  python3 - "$json_path" <<'PY'
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

assert_no_standalone_watcher() {
  output_path="$1"
  if grep -q "InjectionLite: Watching for source changes" "$output_path"; then
    echo "Unexpected InjectionLite standalone watcher in Agent mode." >&2
    cat "$output_path" >&2 || true
    cat "$DAEMON_LOG" >&2 || true
    return 1
  fi
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

TOTAL_SWIFT=$((FEATURE_PROJECT_COUNT * (SWIFT_FILLERS_PER_FEATURE + 1) + MAIN_SWIFT_FILLERS + 2))
TOTAL_OBJC_IMPL=$((FEATURE_PROJECT_COUNT * OBJC_FILLERS_PER_FEATURE + MAIN_OBJC_FILLERS + 6))
TOTAL_OBJC_FILES=$((TOTAL_OBJC_IMPL * 2))

echo "==> Stress profile"
echo "    feature xcodeproj: $FEATURE_PROJECT_COUNT"
echo "    Swift compile units: $TOTAL_SWIFT"
echo "    ObjC .m compile units: $TOTAL_OBJC_IMPL"
echo "    ObjC .h + .m files: ~$TOTAL_OBJC_FILES"

FEATURE_PROJECTS_ROOT="$SMOKE_DIR/FeatureProjects"
FEATURE_SOURCES=()
FEATURE_MODULES=()
FEATURE_DIRS=()
FEATURE_BUILD_LOGS=()
FEATURE_FRAMEWORKS=()

echo "==> Build $FEATURE_PROJECT_COUNT independent mixed Swift/ObjC feature projects"
for index in $(seq 1 "$FEATURE_PROJECT_COUNT"); do
  suffix="$(printf '%02d' "$index")"
  module="SmokeFeature$suffix"
  feature_dir="$FEATURE_PROJECTS_ROOT/Feature$suffix"
  feature_source="$feature_dir/Sources/$module.swift"
  feature_project="$feature_dir/$module.xcodeproj"
  feature_build_log="$ARTIFACTS/feature-$suffix-xcodebuild.log"

  if [ ! -f "$feature_source" ] || [ ! -d "$feature_project" ]; then
    echo "Generated feature project is incomplete: $feature_dir" >&2
    exit 1
  fi

  FEATURE_SOURCES+=("$feature_source")
  FEATURE_MODULES+=("$module")
  FEATURE_DIRS+=("$feature_dir")
  FEATURE_BUILD_LOGS+=("$feature_build_log")
  FEATURE_FRAMEWORKS+=(
    "$DERIVED/Build/Products/Debug-iphonesimulator/$module.framework"
  )

  echo "    -> $module"
  set +e
  xcodebuild \
    -project "$feature_project" \
    -scheme "$module" \
    -configuration Debug \
    -sdk iphonesimulator \
    -destination "platform=iOS Simulator,id=$UDID" \
    -derivedDataPath "$DERIVED" \
    build 2>&1 | tee "$feature_build_log"
  FEATURE_XCODE_STATUS=${PIPESTATUS[0]}
  set -e

  if [ "$FEATURE_XCODE_STATUS" != "0" ]; then
    echo "$module build failed." >&2
    exit "$FEATURE_XCODE_STATUS"
  fi
done

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

echo "==> Seed captured Swift frontend commands from all project builds"
FRONTEND_LOG="$HOME/.agentInjectionIII/cache/frontend-commands.log"
mkdir -p "$(dirname "$FRONTEND_LOG")"
: > "$FRONTEND_LOG"

capture_frontend_commands() {
  build_log="$1"
  working_directory="$2"

  python3 - "$build_log" "$working_directory" "$FRONTEND_LOG" <<'PY'
from pathlib import Path
import sys

build_log = Path(sys.argv[1])
working_directory = sys.argv[2]
frontend_log = Path(sys.argv[3])

commands = []
for raw in build_log.read_text(errors="replace").splitlines():
    line = raw.strip()
    if "swift-frontend" not in line:
        continue
    if " -frontend " not in line or " -c " not in line:
        continue
    start = line.find("/")
    if start < 0:
        continue
    commands.append(
        f"{working_directory}\t{line[start:]}"
    )

if not commands:
    raise SystemExit(
        f"No Swift frontend commands found in {build_log}"
    )

with frontend_log.open("a") as stream:
    stream.write("\n".join(commands) + "\n")

print(
    f"Captured {len(commands)} Swift frontend command(s) "
    f"from {build_log.name}"
)
PY
}

capture_frontend_commands "$BUILD_LOG" "$SMOKE_DIR"
for index in $(seq 0 $((FEATURE_PROJECT_COUNT - 1))); do
  capture_frontend_commands \
    "${FEATURE_BUILD_LOGS[$index]}" \
    "${FEATURE_DIRS[$index]}"
done

echo "Captured $(wc -l < "$FRONTEND_LOG" | tr -d ' ') total frontend command(s)"
cp "$FRONTEND_LOG" "$ARTIFACTS/frontend-commands.log"

APP="$DERIVED/Build/Products/Debug-iphonesimulator/SimulatorSmokeApp.app"
if [ ! -d "$APP" ]; then
  echo "Built app not found: $APP" >&2
  exit 1
fi

if [ ! -d "$APP/iOSInjection.bundle" ]; then
  echo "Embedded iOSInjection.bundle not found in smoke app." >&2
  exit 1
fi

mkdir -p "$APP/Frameworks"
for index in $(seq 0 $((FEATURE_PROJECT_COUNT - 1))); do
  feature_framework="${FEATURE_FRAMEWORKS[$index]}"
  module="${FEATURE_MODULES[$index]}"

  if [ ! -d "$feature_framework" ]; then
    echo "Built feature framework not found: $feature_framework" >&2
    exit 1
  fi

  rm -rf "$APP/Frameworks/$module.framework"
  /usr/bin/ditto \
    "$feature_framework" \
    "$APP/Frameworks/$module.framework"
done

echo "==> Start injectiond"
cd "$REPO_ROOT"
AGENT_INJECTION_KEEP_ARTIFACTS=1 "$DAEMON" \
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
SIMCTL_CHILD_INJECTION_DETAIL=1 \
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
TOUCH_EVENT_MARKER="$DATA_CONTAINER/Documents/agentInjection-touch-event.txt"

echo "==> Verify initial Swift behavior across app and all feature projects"
wait_for_marker "BEFORE" "$MARKER"
for index in $(seq 1 "$FEATURE_PROJECT_COUNT"); do
  suffix="$(printf '%02d' "$index")"
  feature_marker="$DATA_CONTAINER/Documents/agentInjection-feature-$suffix.txt"
  wait_for_marker "FEATURE_${suffix}_BEFORE" "$feature_marker"
done

echo "==> Diagnose compiler context for every feature project"
for index in $(seq 0 $((FEATURE_PROJECT_COUNT - 1))); do
  suffix="$(printf '%02d' $((index + 1)))"
  feature_source="${FEATURE_SOURCES[$index]}"
  doctor_json="$ARTIFACTS/feature-$suffix-doctor-before.json"

  set +e
  "$CTL" --socket "$SOCKET" doctor "$feature_source" |
    tee "$doctor_json"
  doctor_status=${PIPESTATUS[0]}
  set -e
  echo "Feature $suffix doctor status: $doctor_status"
done

echo "==> Modify and inject main-app Swift source without rebuild/relaunch"
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

set +e
"$CTL" --socket "$SOCKET" inject "$SOURCE" | tee "$INJECT_JSON"
INJECT_STATUS=${PIPESTATUS[0]}
set -e
if [ "$INJECT_STATUS" != "0" ]; then
  echo "Primary Swift injection command failed." >&2
  cat "$DAEMON_LOG" >&2 2>/dev/null || true
  exit "$INJECT_STATUS"
fi
json_assert_injected "$INJECT_JSON"
assert_no_standalone_watcher "$INJECT_JSON"
wait_for_marker "AFTER" "$MARKER"

echo "==> Hot reload every independent feature xcodeproj"
for index in $(seq 0 $((FEATURE_PROJECT_COUNT - 1))); do
  suffix="$(printf '%02d' $((index + 1)))"
  feature_source="${FEATURE_SOURCES[$index]}"
  feature_marker="$DATA_CONTAINER/Documents/agentInjection-feature-$suffix.txt"
  feature_inject_json="$ARTIFACTS/feature-$suffix-inject.json"
  feature_doctor_json="$ARTIFACTS/feature-$suffix-doctor-after-main.json"

  echo "    -> Feature $suffix: doctor"
  set +e
  "$CTL" --socket "$SOCKET" doctor "$feature_source" |
    tee "$feature_doctor_json"
  doctor_status=${PIPESTATUS[0]}
  set -e
  echo "       doctor status: $doctor_status"

  echo "    -> Feature $suffix: mutate source"
  python3 - "$feature_source" "$suffix" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
suffix = sys.argv[2]
text = path.read_text()
old = f'"FEATURE_{suffix}_BEFORE"'
new = f'"FEATURE_{suffix}_AFTER"'
if old not in text:
    raise SystemExit(
        f"{old} marker source was not found in {path}"
    )
path.write_text(text.replace(old, new, 1))
PY

  echo "    -> Feature $suffix: inject"
  set +e
  "$CTL" --socket "$SOCKET" inject "$feature_source" |
    tee "$feature_inject_json"
  feature_inject_status=${PIPESTATUS[0]}
  set -e

  if [ "$feature_inject_status" != "0" ]; then
    echo "Feature $suffix Swift injection failed." >&2
    cat "$DAEMON_LOG" >&2 2>/dev/null || true
    exit "$feature_inject_status"
  fi

  json_assert_injected "$feature_inject_json"
  assert_no_standalone_watcher "$feature_inject_json"

  echo "    -> Feature $suffix: verify live behavior"
  wait_for_marker "FEATURE_${suffix}_AFTER" "$feature_marker"
done

cp "$HOME/.agentInjectionIII/cache/compile-commands.json" \
  "$ARTIFACTS/compile-commands.json" 2>/dev/null || true

echo "==> Capture framework/rebind symbol diagnostics"
{
  for index in $(seq 0 $((FEATURE_PROJECT_COUNT - 1))); do
    module="${FEATURE_MODULES[$index]}"
    feature_framework="${FEATURE_FRAMEWORKS[$index]}"
    echo "=== $module.framework symbols ==="
    /usr/bin/nm -gjU "$feature_framework/$module" 2>&1 |
      grep -E 'SmokeFeature|smokeFeature' || true
    echo
  done

  echo "=== App debug dylib feature references ==="
  /usr/bin/nm -gjU "$APP/SimulatorSmokeApp.debug.dylib" 2>&1 |
    grep -E 'SmokeFeature|smokeFeature' || true
  echo
  echo "=== App debug dylib dependencies ==="
  /usr/bin/otool -L "$APP/SimulatorSmokeApp.debug.dylib" 2>&1 || true
  echo
  echo "=== Preserved injection dylibs ==="
  find /tmp/agentInjectionIII -maxdepth 1 -name '*.dylib' -print 2>/dev/null |
    sort || true
} > "$ARTIFACTS/feature-symbols.txt"

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

rm -f "$TOUCH_MARKER" "$TOUCH_EVENT_MARKER"

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

echo "==> Verify replayed touch entered UIApplication sendEvent:"
wait_for_marker "REPLAYED" "$TOUCH_EVENT_MARKER"

echo "==> Start AgentTraceBridge method tracing"
"$CTL" --socket "$SOCKET" trace start 'SmokeViewController|tracePulse' |
  tee "$TRACE_START_JSON"

python3 - "$TRACE_START_JSON" <<'PY'
import json, sys

text = open(sys.argv[1]).read()
start = text.find("{")
if start < 0:
    raise SystemExit(1)
data, _ = json.JSONDecoder().raw_decode(text[start:])
trace = data.get("trace") or {}
ok = bool(
    data.get("ok")
    and trace.get("connected")
    and trace.get("active")
)
if not ok:
    print(json.dumps(data, indent=2), file=sys.stderr)
raise SystemExit(0 if ok else 1)
PY

echo "==> Wait for live tracePulse method-call event"
trace_seen=0
for _ in $(seq 1 80); do
  "$CTL" --socket "$SOCKET" trace read 200 > "$TRACE_READ_JSON" 2>/dev/null || true

  if python3 - "$TRACE_READ_JSON" <<'PY'
import json, sys

text = open(sys.argv[1]).read()
start = text.find("{")
if start < 0:
    raise SystemExit(1)
data, _ = json.JSONDecoder().raw_decode(text[start:])
events = (data.get("trace") or {}).get("events") or []
matched = any(
    "tracePulse" in (event.get("text") or "")
    or "SmokeViewController" in (event.get("text") or "")
    for event in events
)
raise SystemExit(0 if data.get("ok") and matched else 1)
PY
  then
    trace_seen=1
    break
  fi

  sleep 0.25
done

if [ "$trace_seen" != "1" ]; then
  echo "No SmokeViewController trace event was observed." >&2
  cat "$TRACE_READ_JSON" >&2 2>/dev/null || true
  cat "$DAEMON_LOG" >&2 2>/dev/null || true
  exit 1
fi

echo "==> Verify SwiftTrace profile snapshot"
"$CTL" --socket "$SOCKET" profile 100 |
  tee "$PROFILE_JSON"

python3 - "$PROFILE_JSON" <<'PY'
import json, sys

text = open(sys.argv[1]).read()
start = text.find("{")
if start < 0:
    raise SystemExit(1)
data, _ = json.JSONDecoder().raw_decode(text[start:])
profile = data.get("profile") or {}
stats = profile.get("stats") or []
matched = any(
    "tracePulse" in (stat.get("method") or "")
    or "SmokeViewController" in (stat.get("method") or "")
    for stat in stats
)
ok = bool(
    data.get("ok")
    and profile.get("connected")
    and stats
    and matched
)
if not ok:
    print(json.dumps(data, indent=2), file=sys.stderr)
raise SystemExit(0 if ok else 1)
PY

echo "==> Verify SwiftTrace call-order snapshot"
"$CTL" --socket "$SOCKET" call-order |
  tee "$CALL_ORDER_JSON"

python3 - "$CALL_ORDER_JSON" <<'PY'
import json, sys

text = open(sys.argv[1]).read()
start = text.find("{")
if start < 0:
    raise SystemExit(1)
data, _ = json.JSONDecoder().raw_decode(text[start:])
signatures = (data.get("callOrder") or {}).get("signatures") or []
matched = any(
    "tracePulse" in signature
    or "SmokeViewController" in signature
    for signature in signatures
)
ok = bool(
    data.get("ok")
    and signatures
    and matched
)
if not ok:
    print(json.dumps(data, indent=2), file=sys.stderr)
raise SystemExit(0 if ok else 1)
PY

echo "==> Stop AgentTraceBridge method tracing"
"$CTL" --socket "$SOCKET" trace stop |
  tee "$TRACE_STOP_JSON"

python3 - "$TRACE_STOP_JSON" <<'PY'
import json, sys

text = open(sys.argv[1]).read()
start = text.find("{")
if start < 0:
    raise SystemExit(1)
data, _ = json.JSONDecoder().raw_decode(text[start:])
trace = data.get("trace") or {}
ok = bool(
    data.get("ok")
    and trace.get("connected")
    and not trace.get("active")
)
if not ok:
    print(json.dumps(data, indent=2), file=sys.stderr)
raise SystemExit(0 if ok else 1)
PY

echo "==> Start SwiftTrace lifetime instance counting"
"$CTL" --socket "$SOCKET" instances start SmokeLifetimeProbe |
  tee "$INSTANCES_START_JSON"

python3 - "$INSTANCES_START_JSON" <<'PY'
import json, sys

text = open(sys.argv[1]).read()
start = text.find("{")
if start < 0:
    raise SystemExit(1)
data, _ = json.JSONDecoder().raw_decode(text[start:])
instances = data.get("instances") or {}
ok = bool(
    data.get("ok")
    and instances.get("active")
)
if not ok:
    print(json.dumps(data, indent=2), file=sys.stderr)
raise SystemExit(0 if ok else 1)
PY

echo "==> Wait for SmokeLifetimeProbe live instances"
instances_seen=0
for _ in $(seq 1 80); do
  "$CTL" --socket "$SOCKET" instances read > "$INSTANCES_READ_JSON" 2>/dev/null || true

  if python3 - "$INSTANCES_READ_JSON" <<'PY'
import json, sys

text = open(sys.argv[1]).read()
start = text.find("{")
if start < 0:
    raise SystemExit(1)
data, _ = json.JSONDecoder().raw_decode(text[start:])
instances = data.get("instances") or {}
counts = instances.get("counts") or []
matched = any(
    "SmokeLifetimeProbe" in (item.get("type") or "")
    and int(item.get("count") or 0) > 0
    for item in counts
)
raise SystemExit(
    0
    if data.get("ok")
       and instances.get("active")
       and matched
    else 1
)
PY
  then
    instances_seen=1
    break
  fi

  sleep 0.25
done

if [ "$instances_seen" != "1" ]; then
  echo "SmokeLifetimeProbe was not reported by lifetime tracking." >&2
  cat "$INSTANCES_READ_JSON" >&2 2>/dev/null || true
  cat "$DAEMON_LOG" >&2 2>/dev/null || true
  exit 1
fi

echo "==> Stop SwiftTrace lifetime instance counting"
"$CTL" --socket "$SOCKET" instances stop |
  tee "$INSTANCES_STOP_JSON"

python3 - "$INSTANCES_STOP_JSON" <<'PY'
import json, sys

text = open(sys.argv[1]).read()
start = text.find("{")
if start < 0:
    raise SystemExit(1)
data, _ = json.JSONDecoder().raw_decode(text[start:])
instances = data.get("instances") or {}
ok = bool(
    data.get("ok")
    and not instances.get("active")
)
if not ok:
    print(json.dumps(data, indent=2), file=sys.stderr)
raise SystemExit(0 if ok else 1)
PY

echo
echo "Simulator smoke test passed:"
echo "  mixed ObjC + Swift: yes"
echo "  CocoaPods (Masonry): yes"
echo "  runtime handshake: yes"
echo "  Swift injection BEFORE -> AFTER: yes"
echo "  feature projects exercised: $FEATURE_PROJECT_COUNT"
echo "  Swift compile units: $TOTAL_SWIFT"
echo "  ObjC .m compile units: $TOTAL_OBJC_IMPL"
echo "  ObjC .h + .m files: ~$TOTAL_OBJC_FILES"
echo "  every feature project BEFORE -> AFTER: yes"
echo "  screenshot: $SCREENSHOT_PNG"
echo "  touch capture command: yes"
echo "  touch replay -> UIApplication sendEvent: yes"
echo "  AgentTraceBridge live method trace: yes"
echo "  SwiftTrace profile snapshot: yes"
echo "  SwiftTrace call order: yes"
echo "  SwiftTrace lifetime instance counts: yes"
