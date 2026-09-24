#!/bin/bash
set -euo pipefail

# Intended to run as an Xcode Run Script build phase.
# If the developer has not installed the local runtime, this is a no-op,
# so teammates can keep their existing InjectionIII.app workflow.

if [ "${CONFIGURATION:-}" != "Debug" ] && [ "${AGENT_INJECTION_FORCE:-0}" != "1" ]; then
  exit 0
fi

ROOT="${AGENT_INJECTION_HOME:-$HOME/.agentInjectionIII}"
SOURCE="${AGENT_INJECTION_RUNTIME:-$ROOT/runtime/iOSInjection.bundle}"

if [ ! -d "$SOURCE" ]; then
  echo "agentInjectionIII: local runtime not installed; skipping."
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

echo "agentInjectionIII: embedded $DEST"
