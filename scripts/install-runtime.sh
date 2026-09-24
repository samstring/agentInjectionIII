#!/bin/bash
set -euo pipefail

UPSTREAM_REPO="${AGENT_INJECTION_UPSTREAM:-https://github.com/johnno1962/InjectionNext.git}"
# Pin the protocol/runtime revision used by agentInjectionIII. Override only
# when intentionally validating a newer InjectionNext wire/runtime version.
UPSTREAM_REF="${AGENT_INJECTION_UPSTREAM_REF:-39eef8a203b5093a8fbb7334d3a59f03624d2c01}"
ROOT="${AGENT_INJECTION_HOME:-$HOME/.agentInjectionIII}"
SRC="$ROOT/upstream/InjectionNext"
BUILD="$ROOT/build"
RUNTIME="$ROOT/runtime"
XCODE_DEV="$(xcode-select -p)"
ARCH="$(uname -m)"

mkdir -p "$ROOT/upstream" "$BUILD" "$RUNTIME"

if [ ! -d "$SRC/.git" ]; then
  git clone "$UPSTREAM_REPO" "$SRC"
fi

git -C "$SRC" fetch origin "$UPSTREAM_REF"
git -C "$SRC" checkout -f FETCH_HEAD
git -C "$SRC" submodule update --init --recursive

PLATFORM_ROOT="$XCODE_DEV/Platforms/iPhoneSimulator.platform"
SWIFT_LIBS="$XCODE_DEV/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/iphonesimulator"
CONCURRENCY_LIBS="$XCODE_DEV/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-5.5/iphonesimulator"
XCTEST_FRAMEWORKS="$PLATFORM_ROOT/Developer/Library/Frameworks"
XCTEST_SUPPORT="$PLATFORM_ROOT/Developer/usr/lib"
XCCORE_FRAMEWORKS="$PLATFORM_ROOT/Developer/Library/PrivateFrameworks"

rm -rf "$BUILD"

xcodebuild \
  -project "$SRC/App/InjectionNext.xcodeproj" \
  -target InjectionBundle \
  -configuration Debug \
  -sdk iphonesimulator \
  SYMROOT="$BUILD" \
  ARCHS="$ARCH" \
  PRODUCT_NAME=iOSInjection \
  PLATFORM_DIR="$PLATFORM_ROOT" \
  LD_RUNPATH_SEARCH_PATHS="@executable_path/Frameworks @loader_path/Frameworks @loader_path/iOSInjection.bundle/Frameworks $SWIFT_LIBS $CONCURRENCY_LIBS $XCTEST_FRAMEWORKS $XCTEST_SUPPORT $XCCORE_FRAMEWORKS"

SOURCE_BUNDLE="$BUILD/Debug-iphonesimulator/iOSInjection.bundle"
DEST_BUNDLE="$RUNTIME/iOSInjection.bundle"

if [ ! -d "$SOURCE_BUNDLE" ]; then
  echo "error: expected runtime bundle not found at $SOURCE_BUNDLE" >&2
  exit 1
fi

rm -rf "$DEST_BUNDLE"
cp -R "$SOURCE_BUNDLE" "$DEST_BUNDLE"

PLIST="$DEST_BUNDLE/Info.plist"

set_plist() {
  local key="$1"
  local value="$2"
  /usr/libexec/PlistBuddy -c "Delete :$key" "$PLIST" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c "Add :$key string $value" "$PLIST"
}

# Agent mode must never fall back to InjectionLite's file watcher.
set_plist INJECTION_NOSTANDALONE 1
set_plist INJECTION_HOST 127.0.0.1
set_plist UserHome "$HOME"

echo
echo "Installed agentInjectionIII runtime:"
echo "  $DEST_BUNDLE"
echo
echo "Next: add scripts/embed-runtime.sh as an optional Debug Run Script phase."
