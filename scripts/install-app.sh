#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIGURATION="${1:-release}"
SOURCE_APP="$REPO_ROOT/dist/AgentInjectionIII.app"
DESTINATION_ROOT="${AGENT_INJECTION_APP_INSTALL_DIR:-$HOME/Applications}"
DESTINATION_APP="$DESTINATION_ROOT/AgentInjectionIII.app"

bash "$SCRIPT_DIR/build-macos-app.sh" "$CONFIGURATION"

mkdir -p "$DESTINATION_ROOT"
rm -rf "$DESTINATION_APP"
cp -R "$SOURCE_APP" "$DESTINATION_APP"

echo
echo "Installed AgentInjectionIII:"
echo "  $DESTINATION_APP"
echo
echo "Double-click AgentInjectionIII.app in Finder or run:"
echo "  open \"$DESTINATION_APP\""
