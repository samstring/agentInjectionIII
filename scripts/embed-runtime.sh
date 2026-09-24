#!/bin/bash
set -euo pipefail

if [ "${CONFIGURATION:-}" != "Debug" ] && [ "${AGENT_INJECTION_FORCE:-0}" != "1" ]; then
  exit 0
fi

ROOT="${AGENT_INJECTION_HOME:-$HOME/.agentInjectionIII}"
PLATFORM="${PLATFORM_NAME:-}"

case "$PLATFORM" in
  iphoneos)
    DEFAULT_SOURCE="$ROOT/runtime/device/iOSDevInjection.bundle"
    DEVICE_MODE=1
    ;;
  *)
    DEFAULT_SOURCE="$ROOT/runtime/simulator/iOSInjection.bundle"
    DEVICE_MODE=0
    ;;
esac

SOURCE="${AGENT_INJECTION_RUNTIME:-$DEFAULT_SOURCE}"

if [ ! -d "$SOURCE" ]; then
  echo "agentInjectionIII: local runtime not installed for PLATFORM_NAME=${PLATFORM:-unknown}; skipping."
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

PLIST="$DEST/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :UserHome" "$PLIST" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :UserHome string $HOME" "$PLIST"

if [ "$DEVICE_MODE" = "1" ]; then
  if [ -z "${CODESIGNING_FOLDER_PATH:-}" ] ||
     [ -z "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
    echo "agentInjectionIII: device runtime requires Xcode code-signing variables." >&2
    exit 1
  fi

  APP_PLIST="$CODESIGNING_FOLDER_PATH/Info.plist"
  /usr/libexec/PlistBuddy -c "Delete :InjectionUserHome" "$APP_PLIST" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c "Add :InjectionUserHome string $HOME" "$APP_PLIST"

  FRAMEWORKS="$CODESIGNING_FOLDER_PATH/Frameworks"
  mkdir -p "$FRAMEWORKS"
  rm -f "$FRAMEWORKS/libiphoneosInjection.dylib"
  ln -sf "../iOSInjection.bundle/iOSDevInjection" "$FRAMEWORKS/libiphoneosInjection.dylib"

  /usr/bin/codesign     -f     --sign "$EXPANDED_CODE_SIGN_IDENTITY"     --timestamp=none     --preserve-metadata=identifier,entitlements,flags     --generate-entitlement-der     "$DEST"
fi

echo "agentInjectionIII: embedded $SOURCE -> $DEST"
