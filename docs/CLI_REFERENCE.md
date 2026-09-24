# injectionctl CLI 使用手册

injectionctl 是 agentInjectionIII 面向 Agent 和开发者的统一控制入口。

所有命令输出 JSON。

Exit code：

~~~text
0  请求成功，response.ok = true
2  CLI 参数错误
3  daemon 无法连接
4  daemon 已响应，但业务操作失败
~~~

建议先：

~~~bash
cd /path/to/agentInjectionIII
swift build

export CTL="$PWD/.build/debug/injectionctl"
export DAEMON="$PWD/.build/debug/injectiond"
~~~

## 1. 启动 injectiond

~~~bash
"$DAEMON"   --project /absolute/path/to/YourProject
~~~

常用参数：

~~~text
--socket PATH
--project ROOT
--runtime-port PORT
--trace-port PORT
--derived-data PATH
--xcode-path /Applications/Xcode.app
--enable-devices
--codesign-identity IDENTITY
--device-testing
--device-libraries OPTIONS
~~~

默认：

~~~text
socket       /tmp/agentInjectionIII.sock
runtime port 8887
trace port   8888
~~~

# 基础命令

## 2. status / targets

~~~bash
"$CTL" status
"$CTL" targets
"$CTL" --target TARGET_ID status
~~~

重点字段：

~~~text
status.backend.appConnected
status.backend.platform
status.backend.arch
status.backend.temporaryPath
~~~

## 3. doctor

~~~bash
"$CTL" doctor
"$CTL" doctor /repo/App/Foo.swift
~~~

建议 Agent 在修改文件前先 doctor 目标 source。

## 4. inject

~~~bash
"$CTL" inject /repo/App/Foo.swift
"$CTL" inject /repo/App/Foo.m
"$CTL" inject /repo/App/Foo.mm
~~~

多文件：

~~~bash
"$CTL" inject   /repo/App/Foo.swift   /repo/App/Bar.m
~~~

成功条件：

~~~text
ok = true
injections[].compiled = true
injections[].injected = true
~~~

## 5. load-dylib

~~~bash
"$CTL" load-dylib /tmp/Patch.dylib
~~~

用于隔离 compiler 问题和 runtime load 问题。

# Runtime 诊断

## 6. logs

~~~bash
"$CTL" logs
"$CTL" logs 100
"$CTL" logs clear
~~~

## 7. events

~~~bash
"$CTL" events
"$CTL" events 100
"$CTL" events clear
~~~

典型 phase：

~~~text
compiling
compiled
signing
injecting
injected
failed
~~~

## 8. last-error

~~~bash
"$CTL" last-error
~~~

## 9. Runtime Environment

只允许 INJECTION_*：

~~~bash
"$CTL" env INJECTION_DETAIL 1
"$CTL" env INJECTION_DETAIL
~~~

第二种写法表示 unset。

# Compiler

## 10. compiler-state

~~~bash
"$CTL" compiler-state
~~~

## 11. compiler-intercept

~~~bash
"$CTL" compiler-intercept state
"$CTL" compiler-intercept on
"$CTL" compiler-intercept off
~~~

注意：on/off 会显式 patch 当前 Xcode toolchain，不会被 daemon 自动打开。

## 12. set-xcode-path / launch-xcode

~~~bash
"$CTL" set-xcode-path /Applications/Xcode.app
"$CTL" launch-xcode
~~~

# Screenshot / Touch

## 13. screenshot

~~~bash
"$CTL" screenshot
"$CTL" screenshot /tmp/app.png
"$CTL" --target TARGET_ID screenshot /tmp/app.png
~~~

## 14. touch

~~~bash
"$CTL" touch capture
"$CTL" touch read
"$CTL" touch replay events.json
~~~

# Trace / Profiling

## 15. trace start / read / stop

~~~bash
"$CTL" trace start
"$CTL" trace start 'Home|Feed'
"$CTL" trace read 200
"$CTL" trace stop
~~~

trace read 为 consuming read，返回后的 event 会从 daemon buffer 移除。

## 16. trace scope

~~~bash
"$CTL" trace scope frameworks
"$CTL" trace scope uikit
"$CTL" trace scope swiftui
"$CTL" trace scope main-all
"$CTL" trace scope framework MyFramework
"$CTL" trace scope package MyPackage
~~~

所有 scope 都可以附加 filter regex。

## 17. profile

~~~bash
"$CTL" profile
"$CTL" profile 100
~~~

返回 invocation count、elapsed、average。

## 18. call-order

~~~bash
"$CTL" call-order
~~~

可用于启动路径分析和 Reorder Project。

## 19. instances

~~~bash
"$CTL" instances start
"$CTL" instances read
"$CTL" instances stop
~~~

# XCTest

## 20. tests

~~~bash
"$CTL" tests read
"$CTL" tests read 50
"$CTL" tests clear
~~~

结果包含：

~~~text
name
passed
failures
durationSeconds
messages
~~~

# SwiftUI

## 21. prepare-swiftui-source / project

~~~bash
"$CTL" prepare-swiftui-source /repo/App/HomeView.swift
"$CTL" prepare-swiftui-project
~~~

# Runtime / Linker

## 22. unhide-symbols

~~~bash
"$CTL" unhide-symbols
~~~

# Project Optimization

## 23. reorder-project

预览：

~~~bash
"$CTL" reorder-project preview /repo/YourProject.xcodeproj
~~~

应用：

~~~bash
"$CTL" reorder-project apply /repo/YourProject.xcodeproj
~~~

首次 apply 会保存 project.pbxproj.preorder。

Agent 推荐固定使用 preview → 确认 → apply。

# Xprobe / Eval

## 24. xprobe

~~~bash
"$CTL" xprobe search UIViewController
"$CTL" xprobe search
"$CTL" xprobe inspect 42
~~~

## 25. eval

~~~bash
"$CTL" eval 42 'self.description'
"$CTL" eval 42 'self.view.backgroundColor = .red'
~~~

Xprobe / SwiftEval 没有链接时返回 XPROBE_UNAVAILABLE。

# 多 Target

## 26. 选择 target

~~~bash
"$CTL" targets

"$CTL" --target TARGET_ID inject Foo.swift
"$CTL" --target TARGET_ID screenshot /tmp/app.png
"$CTL" --target TARGET_ID touch capture
~~~

# 自定义 Socket

Daemon：

~~~bash
"$DAEMON"   --socket /tmp/my-agent.sock   --project /repo/MyApp
~~~

CLI：

~~~bash
"$CTL"   --socket /tmp/my-agent.sock   status
~~~

# Agent 推荐流程

## 27. 修改一个 Swift 文件

~~~bash
"$CTL" status

"$CTL" doctor   /repo/App/Foo.swift

# Agent edits Foo.swift

"$CTL" inject   /repo/App/Foo.swift

"$CTL" screenshot /tmp/after.png
~~~

失败：

~~~bash
"$CTL" last-error
"$CTL" events 50
"$CTL" logs 100
~~~

## 28. 调试方法调用

~~~bash
"$CTL" trace start 'Foo|Bar'

# exercise app

"$CTL" trace read 200
"$CTL" trace stop
~~~

## 29. 注入 XCTest

~~~bash
"$CTL" tests clear
"$CTL" inject /repo/App/Foo.swift
"$CTL" inject /repo/Tests/FooTests.swift
"$CTL" tests read
~~~

# CI / E2E

## 30. Mixed ObjC + Swift + CocoaPods Smoke

直接运行：

~~~bash
bash scripts/test-simulator-smoke.sh
~~~

当前 smoke 覆盖：

~~~text
Objective-C
+ Swift
+ Bridging Header
+ CocoaPods / Masonry
+ iOS Simulator
+ Injection runtime handshake
+ injectionctl inject
+ BEFORE -> AFTER
+ screenshot
~~~

GitHub workflow：

~~~text
.github/workflows/ci.yml
~~~

Job：

~~~text
simulator-smoke
~~~

失败 artifact：

~~~text
simulator-smoke/
├── xcodebuild.log
├── injectiond.log
├── status.json
├── inject.json
├── screenshot.json
├── after.png
└── simulator-app.log
~~~

# Agent 判断规则

不要只看进程是否退出。

推荐同时检查：

~~~text
process exit code == 0
response.ok == true
~~~

对于 inject 再检查：

~~~text
all(injections[].compiled == true)
all(injections[].injected == true)
~~~

对于真实 UI 改动，再配合 screenshot、App marker、logs 或 trace 做行为验证。
