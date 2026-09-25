# ObjC + Swift 多工程热重载实现文档

分支：`feature/objc-swift-hot-reload`

最后同步基线：`main@068d024`

当前文档对应热重载分支实现方向；具体 HEAD 以后续提交为准。

## 1. 当前状态摘要

### 已实现

- 最新 `main` 已同步到本分支
- 单工程 Swift 原有路径保留
- ObjC + Swift + CocoaPods Smoke 基础路径已验证
- compile context 增加 architecture/module/target-triple 信息
- runtime arch 参与 candidate selection
- 多 module ambiguity 不再静默选择
- `doctor SOURCE` 展示 candidate/module/arch 信息
- Xcode 26.3+ compiler interception 路径已增强
- host InjectionLite standalone watcher 已抑制
- cached compile failure 已限制最多一次恢复重试
- activity-log binary/serialization prefix parser 已修复
- Swift batch compile 保留 secondary sources
- 多工程 Simulator fixture 已建立
- 第二个 xcodeproj / Swift Framework fixture 已建立
- 大量 Swift 文件 fixture 已建立

### 尚未完成最终验证

最重要的剩余验收：

```text
SmokeFeature.framework
FEATURE_BEFORE
  -> edit SmokeFeature.swift
  -> inject
FEATURE_AFTER
```

且中间不能 rebuild / reinstall / relaunch。

---

## 2. 主要代码文件

### `Sources/AgentInjectionCore/BuildLogCompiler.swift`

职责：

- compile command discovery
- compiler command cache
- candidate context selection
- Swift / ObjC command rewrite
- missing filelist/PCH recovery
- single-file compile
- injection dylib link
- compiler diagnostics

本分支的主要修改集中在这里。

### `Sources/AgentInjectionCore/CompilerInterception.swift`

职责：

- patch Swift compiler toolchain
- capture frontend command
- support Xcode 26.3+ Swift Driver 调用路径
- unpatch / restore

### `Sources/AgentInjectionCore/InjectionNextRuntime.swift`

职责：

- runtime connection
- target selection
- 使用 runtime platform + arch 调用 compiler
- inject result
- doctor
- unified diagnostics
- pending source integration

### `HostShim/AgentInjectionHostShim.[hm]`

职责：

- host-only InjectionNext sentinel
- 防止 injectionctl/injectiond 因链接 InjectionLite 而启动 standalone source watcher

### `scripts/install-runtime.sh`

职责：

- 构建本地 InjectionNext runtime
- 注入 Agent runtime bridge
- 配置 `INJECTION_NOSTANDALONE`
- 处理 InjectionLite 早期 `+load` standalone guard

### `Examples/SimulatorSmokeApp`

职责：

- 真实 Simulator fixture
- ObjC + Swift
- CocoaPods
- 多工程
- Swift Framework
- 大量 Swift source

### `scripts/test-simulator-smoke.sh`

职责：

- 构建 runtime
- 生成 demo
- build feature project
- build workspace
- 启动 daemon
- 启动 Simulator app
- 修改源码
- explicit inject
- 验证 marker 行为
- 后续 screenshot/touch/trace/profile/instances 回归

---

## 3. Compile Context 实现

`CachedCommand` 当前字段：

```swift
command
logPath
workingDirectory
platform
arch
module
targetTriple
debugConfiguration
```

### 已解决

旧逻辑容易把：

```text
FeatureA / arm64
FeatureA / x86_64
FeatureB / arm64
```

视为同一 source/platform context。

现在：

- 收集多个 candidate
- runtime arch 参与选择
- module 参与 context identity
- 重复 context 去重
- 无法消歧时返回 `COMPILE_COMMAND_AMBIGUOUS`

### 尚未完全实现

以下仍不是稳定的一等 context 字段：

- workspace
- xcodeproj
- target
- configuration

这些是后续增强项，不应在当前文档中描述为已经完成。

---

## 4. Swift Batch Rewrite

旧实现：

```text
-primary-file Foo.swift
-primary-file Bar.swift
-primary-file Baz.swift
```

注入 Foo 后会错误变成：

```text
-primary-file Foo.swift
```

导致 Bar/Baz 内声明可能不可见。

当前实现：

```text
-primary-file Foo.swift
Bar.swift
Baz.swift
```

即其他 primary source 降级为 secondary source。

### filelist 特例

若原 command 包含：

```text
-filelist Sources.txt
```

则 secondary source 已由 filelist 提供，其他 primary pair 可以直接删除。

---

## 5. Activity Log Parser 修复

CI 曾观察到 command 被解析为：

```text
36"E0157793-..."026235...(20738"/Applications/Xcode_26.6.app/.../swift-frontend
```

最终 shell 报：

```text
zsh: unmatched "
```

根因：

- `.xcactivitylog` 为结构化/二进制日志
- executable 前可能没有 whitespace
- 原 `findExecutableStart()` 只向前找 whitespace

当前实现把以下也作为边界：

- quote
- single quote
- control byte

并加入真实 CI 前缀形态的单元测试。

---

## 6. Cache Retry 修复

旧路径：

```text
cached command fails
 -> invalidate
 -> compileAndLink()
 -> ingest intercepted commands again
 -> same bad command restored
 -> recurse
```

在 CI 曾表现为 daemon 最终 `SIGSEGV 11`。

当前路径：

```text
attempt #1
 -> cached compile fails
 -> invalidate

attempt #2
 -> no unlimited recursive retry
 -> return real error
```

因此后续能看到真实：

- COMPILE_FAILED
- LINK_FAILED
- COMMAND_NOT_FOUND

而不是 stack overflow。

---

## 7. Host Standalone Watcher 修复

曾经 CI 中看到：

```text
InjectionLite: Watching for source changes...
```

这来自 host executable 链接 InjectionLite 后启动的 standalone watcher，不是我们需要的 pending watcher。

当前实现：

- `AgentInjectionHostShim` 声明 host-only InjectionNext sentinel
- `injectionctl` 和 `injectiond` 显式链接并调用 shim
- `BuildLogCompiler` 初始化时也 force-link shim
- runtime build 设置 `INJECTION_NOSTANDALONE`

目标行为：

```text
ProjectFileWatcher
  -> pending only

InjectionLite standalone watcher
  -> disabled
```

---

## 8. Main 同步后的新增功能

本分支已同步当前 `main` 的：

- AgentInjectionIII Menu Bar App
- daemon lifecycle management
- PendingSourceStore / ProjectFileWatcher
- `pending`
- `inject-pending`
- `Control + -`
- unified `diagnostics`
- device/LAN trace
- diagnostic log history
- InjectionIII compatibility path
- signing identity refresh

这些功能和热重载设计的关系：

```text
save source
 -> pending

Agent/Menu/CLI/MCP/Control+-
 -> explicit injection
```

因此不会重新引入“保存即自动注入”的行为。

---

## 9. 当前 Simulator Fixture

### 主工程

```text
SimulatorSmokeApp
├── Objective-C application/bootstrap
├── Swift SmokeViewController
└── CocoaPods
    └── Masonry
```

已验证过：

```text
BEFORE -> AFTER
```

### 第二工程

```text
FeatureProject/
├── SmokeFeature.xcodeproj
└── Sources/
    ├── SmokeFeature.swift
    └── Generated/
        ├── Filler000.swift
        ├── ...
        └── Filler063.swift
```

构建：

```text
SmokeFeature.framework
```

App 启动前将 Framework 放入 App Frameworks，并在运行中验证其 marker。

目标：

```text
FEATURE_BEFORE -> FEATURE_AFTER
```

---

## 10. 当前测试矩阵

| 场景 | 状态 |
|---|---|
| Swift build | 已验证过 |
| MCP transport | 已验证 |
| InjectionIII compatibility | 已验证 |
| Menu App build | 已验证 |
| ObjC + Swift 基础工程 | 已验证 |
| CocoaPods | 已验证 |
| 主 App Swift BEFORE -> AFTER | 已验证 |
| runtime arch candidate selection | 单测覆盖 |
| module ambiguity | 单测覆盖 |
| activity-log binary prefix | 单测覆盖 |
| bounded cache retry | 单测覆盖 |
| batch Swift secondary source | 已实现，测试正在调整 |
| 第二 xcodeproj Swift Framework | 尚未最终通过 |
| FEATURE_BEFORE -> FEATURE_AFTER | 尚未最终通过 |

---

## 11. 当前 CI Blocker

最近一次 CI 在进入 Simulator smoke 前，被一个旧测试预期挡住。

测试：

```text
testSwiftRewriteHandlesQuotedSourceWithSpaces
```

旧预期：

```text
other Swift source should disappear
```

新正确语义：

```text
other Swift source should remain
but must not remain -primary-file
```

因此需要更新该测试：

```swift
XCTAssertTrue(rewritten.contains(other))
XCTAssertFalse(
    rewritten.contains("-primary-file \(other)")
)
```

这属于测试同步，不代表新 batch rewrite 设计失败。

---

## 12. 下一步实现顺序

### Step 1

修正旧 unit test，使其符合 secondary source 新语义。

### Step 2

跑：

```text
swift build
swift test
InjectionIII compatibility
Menu App build
MCP
```

### Step 3

重新进入 Simulator smoke。

### Step 4

验证：

```text
BEFORE -> AFTER
```

### Step 5

验证：

```text
FEATURE_BEFORE -> FEATURE_AFTER
```

### Step 6

如果第二工程仍失败，按以下顺序定位：

1. compile command
2. secondary source context
3. explicit Swift module map
4. Framework link flags
5. Framework runtime image
6. `-interposable`
7. runtime rebound / patched symbol count

---

## 13. 后续增强项

这些不阻塞当前第一阶段 E2E，但建议后续继续做。

### 13.1 完整 Build Context

把以下字段变成一等模型：

```text
workspace
project
target
configuration
module
platform
arch
```

### 13.2 Build Log Index

从“注入时扫描多个 activity log”升级为：

```text
build/update
 -> index compile contexts

inject
 -> direct lookup
```

降低大型 workspace 的 lookup 成本。

### 13.3 Runtime Image Diagnostics

doctor 增加：

- source 对应 Framework image 是否已加载
- image path
- module/image mapping

### 13.4 Interposable Diagnostics

自动判断 source 所属动态 Framework / Package 是否使用：

```text
-Xlinker -interposable
```

### 13.5 No-effect Injection

若 runtime 能提供 rebound count：

```text
loaded dylib
rebound = 0
```

应返回 warning/failure，而不是简单报告 injected=true。

---

## 14. 完成定义

最终本分支只有在以下条件同时满足时才算完成：

```text
single-project regression       ✅
ObjC + Swift                    ✅
CocoaPods                       ✅
large Swift target              ✅
multi-project compile context   ✅
second-project framework        ✅
BEFORE -> AFTER                 ✅
FEATURE_BEFORE -> FEATURE_AFTER ✅
CI                              ✅
```
