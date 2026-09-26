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
SIMULATOR_ONLY="${AGENT_INJECTION_SIMULATOR_ONLY:-0}"

mkdir -p "$ROOT/upstream" "$BUILD" "$RUNTIME/simulator" "$RUNTIME/device"

if [ ! -d "$SRC/.git" ]; then
  git clone "$UPSTREAM_REPO" "$SRC"
fi

git -C "$SRC" fetch origin "$UPSTREAM_REF"
git -C "$SRC" checkout -f FETCH_HEAD
git -C "$SRC" submodule update --init --recursive

# Agent mode must never fall back to InjectionLite's save watcher. InjectionNext
# normally prevents that by noticing its client class during +load, but custom
# bundle link/load order can let InjectionLite start first. Honor the existing
# INJECTION_NOSTANDALONE setting in that earlier +load path as well.
INJECTION_BOOT="$SRC/InjectionLite/Sources/InjectionImplC/InjectionBoot.mm"
python3 - "$INJECTION_BOOT" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
needle = """    static NSObject *singleton;
    if (objc_getClass("InjectionNext")) return;
"""
replacement = """    static NSObject *singleton;
    if (_insetting(@INJECTION_NOSTANDALONE)) return;
    if (objc_getClass("InjectionNext")) return;
"""

if replacement in text:
    raise SystemExit(0)
if needle not in text:
    raise SystemExit(
        "Unable to patch InjectionLite standalone guard; "
        "upstream InjectionBoot.mm changed."
    )
path.write_text(text.replace(needle, replacement, 1))
PY

# Compile the Agent-only Swift introspection bridge into the locally built
# InjectionNext runtime. This keeps SwiftTrace lifetime/call-order APIs out of
# the user's application target while making them available over ObjC runtime.
cp "$REPO_ROOT/Runtime/AgentInjectionRuntimeBridge.swift" \
   "$SRC/Sources/InjectionNext/AgentInjectionRuntimeBridge.swift"

# InjectionNext.xcodeproj uses explicit PBX file/build references rather than a
# synchronized folder group. Copying a new Swift source into Sources/ is not
# enough to compile it into InjectionBundle, so add the Agent bridge to the
# project and target sources phase deterministically.
PROJECT_FILE="$SRC/App/InjectionNext.xcodeproj/project.pbxproj"
python3 - "$PROJECT_FILE" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

build_id = "A61E50012F00000100A61E50"
file_id = "A61E50022F00000100A61E50"
name = "AgentInjectionRuntimeBridge.swift"

if f"{name} in Sources" in text:
    raise SystemExit(0)

replacements = [
    (
        "/* Begin PBXBuildFile section */\n",
        "/* Begin PBXBuildFile section */\n"
        f"\t\t{build_id} /* {name} in Sources */ = "
        f"{{isa = PBXBuildFile; fileRef = {file_id} /* {name} */; }};\n",
    ),
    (
        "/* Begin PBXFileReference section */\n",
        "/* Begin PBXFileReference section */\n"
        f"\t\t{file_id} /* {name} */ = "
        "{isa = PBXFileReference; fileEncoding = 4; "
        "lastKnownFileType = sourcecode.swift; "
        f"name = {name}; "
        f"path = ../../Sources/InjectionNext/{name}; "
        'sourceTree = "<group>"; };\n',
    ),
    (
        "\t\t\t\tBBDD84182C4FE7E6000F3124 /* InjectionNext.swift */,\n"
        "\t\t\t\tBBDD84532C4FEB16000F3124 /* TupleRegex.swift */,",
        "\t\t\t\tBBDD84182C4FE7E6000F3124 /* InjectionNext.swift */,\n"
        f"\t\t\t\t{file_id} /* {name} */,\n"
        "\t\t\t\tBBDD84532C4FEB16000F3124 /* TupleRegex.swift */,",
    ),
    (
        "\t\t\t\tBBDD84422C4FEA4E000F3124 /* InjectionNext.swift in Sources */,\n",
        "\t\t\t\tBBDD84422C4FEA4E000F3124 /* InjectionNext.swift in Sources */,\n"
        f"\t\t\t\t{build_id} /* {name} in Sources */,\n",
    ),
]

for needle, replacement in replacements:
    if needle not in text:
        raise SystemExit(
            f"Unable to add {name} to InjectionBundle; "
            f"upstream project structure changed near: {needle!r}"
        )
    text = text.replace(needle, replacement, 1)

path.write_text(text)
PY

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
    'OTHER_LDFLAGS=$(inherited) -Xlinker -u -Xlinker _AgentInjectionRuntimeBridgeAnchor' \
    LD_RUNPATH_SEARCH_PATHS="@executable_path/Frameworks @loader_path/Frameworks @loader_path/${family}Injection.bundle/Frameworks $swift_libs $concurrency_libs $xctest_frameworks $xctest_support $xccore_frameworks"

  local source_bundle="$BUILD/Debug-$sdk/${family}Injection.bundle"
  if [ ! -d "$source_bundle" ]; then
    echo "error: expected runtime bundle not found at $source_bundle" >&2
    exit 1
  fi

  local runtime_binary="$source_bundle/${family}Injection"
  if ! /usr/bin/nm -gjU "$runtime_binary" 2>/dev/null |
       grep -q '_AgentInjectionRuntimeBridgeAnchor'; then
    echo "error: AgentInjectionRuntimeBridge linker root is missing from $runtime_binary" >&2
    exit 1
  fi

  if ! /usr/bin/strings "$runtime_binary" |
       grep -Fq 'AgentInjectionRuntimeBridge'; then
    echo "error: AgentInjectionRuntimeBridge Objective-C runtime name is missing from $runtime_binary" >&2
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

SIM_PLIST="$SIM_BUNDLE/Info.plist"
set_plist "$SIM_PLIST" INJECTION_NOSTANDALONE 1
set_plist "$SIM_PLIST" INJECTION_HOST 127.0.0.1
set_plist "$SIM_PLIST" UserHome "$HOME"

if [ "$SIMULATOR_ONLY" != "1" ]; then
  build_runtime iOSDev iphoneos iPhoneOS iphoneos arm64 "$DEVICE_BUNDLE"

  DEVICE_PLIST="$DEVICE_BUNDLE/Info.plist"
  set_plist "$DEVICE_PLIST" INJECTION_NOSTANDALONE 1
  /usr/libexec/PlistBuddy -c "Delete :INJECTION_HOST" "$DEVICE_PLIST" >/dev/null 2>&1 || true
  set_plist "$DEVICE_PLIST" UserHome "$HOME"
fi

echo
echo "Installed AgentInjectionIII runtimes:"
echo "  simulator: $SIM_BUNDLE"
if [ "$SIMULATOR_ONLY" != "1" ]; then
  echo "  device:    $DEVICE_BUNDLE"
  echo
  echo "Device runtime deliberately has no INJECTION_HOST setting so it can use InjectionNext multicast discovery."
else
  echo "  device:    skipped (AGENT_INJECTION_SIMULATOR_ONLY=1)"
fi
; then
    echo "error: AgentInjectionRuntimeBridge Objective-C runtime name is missing from $runtime_binary" >&2
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

SIM_PLIST="$SIM_BUNDLE/Info.plist"
set_plist "$SIM_PLIST" INJECTION_NOSTANDALONE 1
set_plist "$SIM_PLIST" INJECTION_HOST 127.0.0.1
set_plist "$SIM_PLIST" UserHome "$HOME"

if [ "$SIMULATOR_ONLY" != "1" ]; then
  build_runtime iOSDev iphoneos iPhoneOS iphoneos arm64 "$DEVICE_BUNDLE"

  DEVICE_PLIST="$DEVICE_BUNDLE/Info.plist"
  set_plist "$DEVICE_PLIST" INJECTION_NOSTANDALONE 1
  /usr/libexec/PlistBuddy -c "Delete :INJECTION_HOST" "$DEVICE_PLIST" >/dev/null 2>&1 || true
  set_plist "$DEVICE_PLIST" UserHome "$HOME"
fi

echo
echo "Installed AgentInjectionIII runtimes:"
echo "  simulator: $SIM_BUNDLE"
if [ "$SIMULATOR_ONLY" != "1" ]; then
  echo "  device:    $DEVICE_BUNDLE"
  echo
  echo "Device runtime deliberately has no INJECTION_HOST setting so it can use InjectionNext multicast discovery."
else
  echo "  device:    skipped (AGENT_INJECTION_SIMULATOR_ONLY=1)"
fi
