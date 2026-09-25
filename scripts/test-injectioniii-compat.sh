#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

AGENT_HOME="$TMP_ROOT/agent-home"
BUILD_ROOT="$TMP_ROOT/build"

mkdir -p "$AGENT_HOME" "$BUILD_ROOT"

CONFIGURATION=Debug \
PLATFORM_NAME=iphonesimulator \
AGENT_INJECTION_HOME="$AGENT_HOME" \
TARGET_BUILD_DIR="$BUILD_ROOT" \
UNLOCALIZED_RESOURCES_FOLDER_PATH="Compat.app" \
bash "$REPO_ROOT/scripts/embed-runtime.sh"

if [ -e "$BUILD_ROOT/Compat.app/iOSInjection.bundle" ]; then
  echo "error: Agent runtime was embedded even though no local Agent runtime exists" >&2
  exit 1
fi

CLASSIC="/Applications/InjectionIII.app/Contents/Resources/iOSInjection.bundle"

if ! grep -Fq "$CLASSIC" \
  "$REPO_ROOT/Integration/AgentInjectionBootstrap.m"; then
  echo "error: classic InjectionIII fallback path is missing" >&2
  exit 1
fi

if grep -Fq 'rm -rf "/Applications/InjectionIII.app' \
  "$REPO_ROOT/scripts/embed-runtime.sh"; then
  echo "error: embed script must never mutate InjectionIII.app" >&2
  exit 1
fi

echo "InjectionIII compatibility smoke passed:"
echo "  no local Agent runtime -> embed step is a no-op"
echo "  classic InjectionIII fallback remains present"
