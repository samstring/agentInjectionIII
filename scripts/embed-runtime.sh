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

  sign_item() {
    /usr/bin/codesign \
      -f \
      --sign "$EXPANDED_CODE_SIGN_IDENTITY" \
      --timestamp=none \
      --preserve-metadata=identifier,entitlements,flags \
      --generate-entitlement-der \
      "$1"
  }

  # Match InjectionNext device support: developer frameworks and dylibs
  # referenced by the device injection runtime must travel inside the app.
  shopt -s nullglob
  DEV_ITEMS=(
    "$PLATFORM_DEVELOPER_LIBRARY_DIR"/*Frameworks/XC*
    "$PLATFORM_DEVELOPER_LIBRARY_DIR"/*Frameworks/StoreKit*
    "$PLATFORM_DEVELOPER_USR_DIR"/lib/*.dylib
  )

  for item in "${DEV_ITEMS[@]}"; do
    name="$(basename "$item")"
    copied="$FRAMEWORKS/$name"
    rm -rf "$copied"
    /usr/bin/rsync -a "$item" "$FRAMEWORKS/"
    sign_item "$copied" || true
  done

  if [ "${AGENT_INJECTION_DEVICE_TESTING:-0}" = "1" ]; then
    PRODUCTS_DIR="$(dirname "$CODESIGNING_FOLDER_PATH")"
    rm -f /tmp/InjectionNext.Products
    ln -s "$PRODUCTS_DIR" /tmp/InjectionNext.Products

    TEST_ITEMS=(
      "$PLATFORM_DEVELOPER_LIBRARY_DIR"/Frameworks/_Testing_*.framework
    )

    if [ -n "${AGENT_INJECTION_TESTING_FRAMEWORKS:-}" ]; then
      IFS=';' read -r -a EXTRA_TEST_ITEMS <<< "$AGENT_INJECTION_TESTING_FRAMEWORKS"
      TEST_ITEMS+=("${EXTRA_TEST_ITEMS[@]}")
    fi

    for item in "${TEST_ITEMS[@]}"; do
      [ -e "$item" ] || continue
      name="$(basename "$item")"
      copied="$FRAMEWORKS/$name"
      rm -rf "$copied"
      /usr/bin/rsync -a "$item" "$FRAMEWORKS/"
      sign_item "$copied"
    done

    TESTING="$PLATFORM_DEVELOPER_LIBRARY_DIR/Frameworks/Testing.framework"
    if [ -d "$TESTING" ]; then
      rm -rf "$FRAMEWORKS/Testing.framework"
      /usr/bin/rsync -a "$TESTING" "$FRAMEWORKS/"
      sign_item "$FRAMEWORKS/Testing.framework"
    fi
  fi

  sign_item "$DEST"
fi

echo "agentInjectionIII: embedded $SOURCE -> $DEST"
