#!/bin/bash
set -euo pipefail

if [ "${CONFIGURATION:-}" != "Debug" ] && [ "${AGENT_INJECTION_FORCE:-0}" != "1" ]; then
  exit 0
fi

ROOT="${AGENT_INJECTION_HOME:-$HOME/.agentInjectionIII}"

case "${PLATFORM_NAME:-}" in
  iphoneos|appletvos|xros)
    DEFAULT_SOURCE="$ROOT/runtime/device/iOSInjection.bundle"
    ;;
  *)
    DEFAULT_SOURCE="$ROOT/runtime/simulator/iOSInjection.bundle"
    ;;
esac

SOURCE="${AGENT_INJECTION_RUNTIME:-$DEFAULT_SOURCE}"

if [ ! -d "$SOURCE" ]; then
  echo "agentInjectionIII: local runtime not installed for PLATFORM_NAME=${PLATFORM_NAME:-unknown}; skipping."
  echo "  expected: $SOURCE"
  exit 0
fi

if [ -z "${TARGET_BUILD_DIR:-}" ] || [ -z "${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}" ]; then
  echo "agentInjectionIII: Xcode build variables are unavailable; skipping."
  exit 0
fi

DEST_DIR="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
DEST="$DEST_DIR/iOSInjection.bundle"

mkdir -p "$DEST_DIR"
rm -rf "$DEST"
rsync -a "$SOURCE/" "$DEST/"

echo "agentInjectionIII: embedded $SOURCE -> $DEST"
