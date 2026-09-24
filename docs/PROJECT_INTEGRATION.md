# agentInjectionIII 项目接入指南

本文档面向现有的 Objective-C + Swift 混编 + CocoaPods iOS 工程，说明如何接入 agentInjectionIII，并在本机或 GitHub Actions iOS Simulator 中使用。

> 核心原则：由 Agent 显式决定何时注入。保存源文件本身不会自动触发注入。

## 1. 适用项目

推荐场景：

- iOS Debug 工程
- Objective-C + Swift 混编
- CocoaPods workspace
- Xcode / iOS Simulator
- 可以修改 Debug Build Settings

仓库中的真实示例位于：

~~~text
Examples/SimulatorSmokeApp
~~~

示例结构：

~~~text
Objective-C AppDelegate
        ↓
Swift SmokeViewController
        ↓
Bridging Header
        ↓
Objective-C SmokeObjCHelper
        ↓
CocoaPods / Masonry
~~~

## 2. 工作架构

~~~text
Agent / Developer
      ↓
injectionctl
      ↓ JSON / Unix Domain Socket
injectiond
      ├─ compiler command recovery
      ├─ compiler interception
      ├─ compile / link injection dylib
      ├─ trace / profile / XCTest result server
      └─ InjectionNext-compatible runtime server :8887
                ↓
       iOSInjection.bundle
                ↓
          running Debug App
~~~

默认地址：

~~~text
control socket : /tmp/agentInjectionIII.sock
runtime TCP    : 127.0.0.1:8887
trace TCP      : 127.0.0.1:8888
~~~

## 3. 第一次安装

~~~bash
export AGENT_INJECTION_REPO=/path/to/agentInjectionIII
cd "$AGENT_INJECTION_REPO"

swift build
~~~

构建后可直接使用：

~~~text
.build/debug/injectiond
.build/debug/injectionctl
~~~

安装本地 runtime：

~~~bash
bash scripts/install-runtime.sh
~~~

只安装 Simulator runtime：

~~~bash
AGENT_INJECTION_SIMULATOR_ONLY=1   bash scripts/install-runtime.sh
~~~

默认位置：

~~~text
~/.agentInjectionIII/runtime/simulator/iOSInjection.bundle
~/.agentInjectionIII/runtime/device/iOSDevInjection.bundle
~~~

Simulator runtime 使用：

~~~text
INJECTION_HOST=127.0.0.1
INJECTION_NOSTANDALONE=1
~~~

INJECTION_NOSTANDALONE=1 用来避免 daemon 不存在时退回传统的保存文件自动注入行为。

## 4. CocoaPods 工程接入

### 4.1 不需要修改 Podfile

原项目继续正常执行：

~~~bash
pod install
open YourProject.xcworkspace
~~~

agentInjectionIII 会复用 Xcode 已经生成的真实 compiler command，因此 CocoaPods 的 Header Search Paths、Framework Search Paths、module maps、bridging header、defines、SDK、architecture 和 Swift frontend flags 都会沿用。

### 4.2 加入 Integration 文件

把下面四个文件加入 App target：

~~~text
Integration/AgentInjectionBootstrap.h
Integration/AgentInjectionBootstrap.m
Integration/AgentTraceBridge.h
Integration/AgentTraceBridge.m
~~~

### 4.3 App 启动时加载 runtime

Objective-C AppDelegate 示例：

~~~objc
#import "AgentInjectionBootstrap.h"

- (BOOL)application:(UIApplication *)application
didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
#if DEBUG
    [AgentInjectionBootstrap start];
#endif

    return YES;
}
~~~

Bootstrap 会优先加载 App 内嵌的 iOSInjection.bundle。如果不存在，则可以兼容回退到 /Applications/InjectionIII.app 中的 runtime。

## 5. Debug Build Settings

Debug target 需要：

~~~text
OTHER_LDFLAGS = $(inherited) -Xlinker -interposable
~~~

推荐同时开启：

~~~text
EMIT_FRONTEND_COMMAND_LINES = YES
COMPILATION_CACHE_ENABLE_CACHING = NO
~~~

混编项目原有 bridging header 保持不变，例如：

~~~text
SWIFT_OBJC_BRIDGING_HEADER =
  YourProject/YourProject-Bridging-Header.h
~~~

不需要为 agentInjectionIII 建第二套 bridging header。

## 6. 增加 Embed Runtime Build Phase

在 App target 的 Build Phases 中增加 Debug Run Script：

~~~bash
bash "/absolute/path/to/agentInjectionIII/scripts/embed-runtime.sh"
~~~

如果本机没有安装 Agent runtime，这个脚本会 no-op，因此不会强迫所有团队成员安装。

## 7. 第一次完整构建

CocoaPods 工程使用 workspace：

~~~bash
pod install

xcodebuild   -workspace YourProject.xcworkspace   -scheme YourScheme   -configuration Debug   -sdk iphonesimulator   build
~~~

至少完整构建一次，让 Xcode 产生 compiler command / build log。

## 8. 启动 daemon

推荐使用已构建 binary：

~~~bash
AGENT_ROOT=/path/to/agentInjectionIII

"$AGENT_ROOT/.build/debug/injectiond"   --project /absolute/path/to/YourProject
~~~

固定 DerivedData：

~~~bash
"$AGENT_ROOT/.build/debug/injectiond"   --project /absolute/path/to/YourProject   --derived-data /absolute/path/to/DerivedData
~~~

指定 Xcode：

~~~bash
"$AGENT_ROOT/.build/debug/injectiond"   --project /absolute/path/to/YourProject   --xcode-path /Applications/Xcode.app
~~~

## 9. 启动 App 并检查

启动 Debug Simulator App 后：

~~~bash
CTL=/path/to/agentInjectionIII/.build/debug/injectionctl

"$CTL" status
~~~

重点检查：

~~~text
status.backend.appConnected = true
~~~

然后：

~~~bash
"$CTL" doctor
"$CTL" doctor /absolute/path/to/YourProject/Sources/Foo.swift
~~~

## 10. 注入 Swift / Objective-C

Swift：

~~~bash
"$CTL" inject /absolute/path/to/YourProject/Sources/Foo.swift
~~~

Objective-C：

~~~bash
"$CTL" inject /absolute/path/to/YourProject/Sources/Foo.m
~~~

Objective-C++：

~~~bash
"$CTL" inject /absolute/path/to/YourProject/Sources/Foo.mm
~~~

多文件：

~~~bash
"$CTL" inject   Sources/Foo.swift   Sources/Bar.m
~~~

Agent 应检查：

~~~text
response.ok == true
injections[].compiled == true
injections[].injected == true
~~~

## 11. Compiler Interception

查看状态：

~~~bash
"$CTL" compiler-intercept state
~~~

显式开启：

~~~bash
"$CTL" compiler-intercept on
~~~

重新在 Xcode build 一次，然后检查：

~~~bash
"$CTL" compiler-state
~~~

结束后关闭：

~~~bash
"$CTL" compiler-intercept off
~~~

注意：on/off 会显式修改当前选择的 Xcode toolchain。daemon 启动不会自动开启 interception；build-log provider 始终保留作为 fallback。

## 12. Screenshot / Trace / Profile

Screenshot：

~~~bash
"$CTL" screenshot /tmp/app.png
~~~

Trace：

~~~bash
"$CTL" trace start 'Feed|Home'
"$CTL" trace read 200
"$CTL" trace stop
~~~

SwiftUI：

~~~bash
"$CTL" trace scope swiftui
~~~

Profile：

~~~bash
"$CTL" profile 100
~~~

Instance Counts：

~~~bash
"$CTL" instances start
"$CTL" instances read
"$CTL" instances stop
~~~

Call Order：

~~~bash
"$CTL" call-order
~~~

## 13. XCTest Injection

推荐流程：

~~~text
修改业务代码
→ inject Foo.swift
→ 修改 FooTests.swift
→ inject FooTests.swift
→ runtime 执行 injected XCTest
→ tests read
~~~

命令：

~~~bash
"$CTL" tests clear
"$CTL" inject /repo/App/Foo.swift
"$CTL" inject /repo/Tests/FooTests.swift
"$CTL" tests read
~~~

## 14. Reorder Project

先获取 call order：

~~~bash
"$CTL" call-order
~~~

只预览：

~~~bash
"$CTL" reorder-project preview YourProject.xcodeproj
~~~

确认后执行：

~~~bash
"$CTL" reorder-project apply YourProject.xcodeproj
~~~

第一次 apply 会保存 project.pbxproj.preorder。

## 15. Xprobe / Eval

Xprobe / Eval 是 optional runtime capability。

~~~bash
"$CTL" xprobe search UIViewController
"$CTL" xprobe inspect 42
"$CTL" eval 42 'self.description'
~~~

没有链接 Xprobe / SwiftEval 时会返回 XPROBE_UNAVAILABLE，不影响普通 Injection。

# CI 接入

## 16. GitHub Actions

当前仓库使用：

~~~yaml
jobs:
  swift:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - run: swift build
      - run: swift test

  simulator-smoke:
    needs: swift
    runs-on: macos-26
    steps:
      - uses: actions/checkout@v4
      - run: bash scripts/test-simulator-smoke.sh
~~~

真实配置见 .github/workflows/ci.yml。

## 17. Mixed ObjC + Swift + CocoaPods Smoke

Demo：

~~~text
Examples/SimulatorSmokeApp/
├── Podfile
├── generate_project.rb
├── Info.plist
└── Sources/
    ├── main.m
    ├── AppDelegate.m
    ├── SmokeObjCHelper.m
    ├── SimulatorSmokeApp-Bridging-Header.h
    └── SmokeViewController.swift
~~~

运行：

~~~bash
bash scripts/test-simulator-smoke.sh
~~~

Smoke 流程：

~~~text
build host tools
→ boot Simulator
→ build local InjectionNext runtime
→ pod install
→ build CocoaPods workspace
→ start injectiond
→ install / launch App
→ runtime handshake
→ marker = BEFORE
→ 只修改 Swift 源码
→ injectionctl inject
→ marker = AFTER
→ screenshot
~~~

AFTER 阶段不会重新 build 或 relaunch App。

## 18. CI Artifact

Smoke job 会上传 simulator-smoke artifact，可能包含：

~~~text
xcodebuild.log
injectiond.log
status.json
inject.json
screenshot.json
after.png
simulator-app.log
~~~

失败时推荐按顺序检查：

~~~text
1. xcodebuild.log
2. injectiond.log
3. status.json
4. inject.json
5. simulator-app.log
~~~

# Agent 推荐工作流

## 19. 最小循环

~~~text
1. status
2. doctor SOURCE
3. Agent 编辑 SOURCE
4. inject SOURCE
5. screenshot / logs / trace 验证
6. 失败时读取 last-error / events
~~~

对应：

~~~bash
"$CTL" status
"$CTL" doctor /repo/App/FeedViewController.swift
"$CTL" inject /repo/App/FeedViewController.swift
"$CTL" screenshot /tmp/after.png
"$CTL" last-error
"$CTL" events 50
~~~

## 20. 常见失败

RUNTIME_NOT_CONNECTED：

- 检查 status.backend.appConnected
- 确认 App 内存在 iOSInjection.bundle
- 确认启动的是 Debug App

COMPILE_FAILED：

- 先运行 doctor SOURCE
- 确认 CocoaPods 已 pod install
- 确认 workspace 已完整 build
- 确认 bridging header 存在
- 检查 EMIT_FRONTEND_COMMAND_LINES
- 检查 COMPILATION_CACHE_ENABLE_CACHING
- 必要时开启 compiler interception

DAEMON_UNAVAILABLE：

~~~bash
ps aux | grep injectiond
ls -l /tmp/agentInjectionIII.sock
~~~

自定义 socket 时 daemon 与 CLI 必须使用同一个路径。

## 21. 真机

仓库已经有真机 transport / signing 基础，但当前接入验收仍建议先以 Simulator 为准；physical-device E2E 单独验证。
