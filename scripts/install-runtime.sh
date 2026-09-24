#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

UPSTREAM_REPO="${AGENT_INJECTION_UPSTREAM:-https://github.com/johnno1962/InjectionNext.git}"
UPSTREAM_REF="${AGENT_INJECTION_UPSTREAM_REF:-39eef8a203b5093a8fbb7334d3a59f03624d2c01}"
ROOT="${AGENT_INJECTION_HOME:-$HOME/.agentInjectionIII}"
SRC="$ROOT/upstream/InjectionNext"
BUILD="$ROOT/build"
RUNTIME="$ROOT/runtime"
XCODE_DEV="$(xcode-select -p)"
ARCH="$(uname -m)"

mkdir -p "$ROOT/upstream" "$BUILD" "$RUNTIME/simulator" "$RUNTIME/device"

if [ ! -d "$SRC/.git" ]; then
  git clone "$UPSTREAM_REPO" "$SRC"
fi

git -C "$SRC" fetch origin "$UPSTREAM_REF"
git -C "$SRC" checkout -f FETCH_HEAD
git -C "$SRC" submodule update --init --recursive

# Compile the Agent-only Swift introspection bridge into the locally built
# InjectionNext runtime. This keeps SwiftTrace lifetime/call-order APIs out of
# the user's application target while making them available over ObjC runtime.
cp "$REPO_ROOT/Runtime/AgentInjectionRuntimeBridge.swift" \
   "$SRC/Sources/InjectionNext/AgentInjectionRuntimeBridge.swift"

rm -rf "$BUILD"

build_runtime() {
  local family="$1"
  local sdk="$2"
  local platform="$3"
  local swift_platform="$4"
  local archs="$5"
  local destination="$6"

  local platform_root="$XCODE_DEV/Platforms/$platform.platform"
  local swift_libs="$XCODE_DEV/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/$swift_platform"
  local concurrency_libs="$XCODE_DEV/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-5.5/$swift_platform"
  local xctest_frameworks="$platform_root/Developer/Library/Frameworks"
  local xctest_support="$platform_root/Developer/usr/lib"
  local xccore_frameworks="$platform_root/Developer/Library/PrivateFrameworks"

  local install_name=""
  if [[ "$family" == *Dev ]]; then
    install_name="LD_DYLIB_INSTALL_NAME=@rpath/lib${sdk}Injection.dylib"
  fi

  xcodebuild \
    -project "$SRC/App/InjectionNext.xcodeproj" \
    -target InjectionBundle \
    -configuration Debug \
    -sdk "$sdk" \
    SYMROOT="$BUILD" \
    ARCHS="$archs" \
    PRODUCT_NAME="${family}Injection" \
    PLATFORM_DIR="$platform_root" \
    CODE_SIGNING_ALLOWED=NO \
    $install_name \
    LD_RUNPATH_SEARCH_PATHS="@executable_path/Frameworks @loader_path/Frameworks @loader_path/${family}Injection.bundle/Frameworks $swift_libs $concurrency_libs $xctest_frameworks $xctest_support $xccore_frameworks"

  local source_bundle="$BUILD/Debug-$sdk/${family}Injection.bundle"
  if [ ! -d "$source_bundle" ]; then
    echo "error: expected runtime bundle not found at $source_bundle" >&2
    exit 1
  fi

  rm -rf "$destination"
  cp -R "$source_bundle" "$destination"
}

set_plist() {
  local plist="$1"
  local key="$2"
  local value="$3"
  /usr/libexec/PlistBuddy -c "Delete :$key" "$plist" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c "Add :$key string $value" "$plist"
}

SIM_BUNDLE="$RUNTIME/simulator/iOSInjection.bundle"
DEVICE_BUNDLE="$RUNTIME/device/iOSDevInjection.bundle"

build_runtime iOS iphonesimulator iPhoneSimulator iphonesimulator "$ARCH" "$SIM_BUNDLE"
build_runtime iOSDev iphoneos iPhoneOS iphoneos arm64 "$DEVICE_BUNDLE"

SIM_PLIST="$SIM_BUNDLE/Info.plist"
DEVICE_PLIST="$DEVICE_BUNDLE/Info.plist"

set_plist "$SIM_PLIST" INJECTION_NOSTANDALONE 1
set_plist "$SIM_PLIST" INJECTION_HOST 127.0.0.1
set_plist "$SIM_PLIST" UserHome "$HOME"

set_plist "$DEVICE_PLIST" INJECTION_NOSTANDALONE 1
/usr/libexec/PlistBuddy -c "Delete :INJECTION_HOST" "$DEVICE_PLIST" >/dev/null 2>&1 || true
set_plist "$DEVICE_PLIST" UserHome "$HOME"

echo
echo "Installed agentInjectionIII runtimes:"
echo "  simulator: $SIM_BUNDLE"
echo "  device:    $DEVICE_BUNDLE"
echo
echo "Device runtime deliberately has no INJECTION_HOST setting so it can use InjectionNext multicast discovery."
