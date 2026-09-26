# ObjC + Swift 多工程热重载技术设计

分支：`feature/objc-swift-hot-reload`

## 1. 总体架构

```text
                     AI Agent
                        |
             +----------+----------+
             |                     |
            MCP              injectionctl
             |                     |
             +----------+----------+
                        |
                 Unix Domain Socket
                        |
                        v
                   injectiond
                        |
          +-------------+-------------+
          |                           |
          v                           v
 BuildLogCompiler              InjectionNextRuntime
          |                           |
          |                           | TCP :8887
          v                           v
 swift-frontend / clang       iOSInjection.bundle
          |                           |
          v                           v
        .o -> dylib          already-running App
```

源码保存本身不触发注入：

```text
FSEvents watcher
   -> PendingSourceStore
   -> explicit inject only
```

---

## 2. 注入主流程

```text
Agent edits Foo.swift
        |
        v
injectionctl inject Foo.swift
        |
        v
InjectionNextRuntimeBackend.inject()
        |
        +--> runtime platform / arch
        |
        v
BuildLogCompiler.compileAndLink()
        |
        +--> ingest intercepted frontend commands
        +--> lookup candidate contexts
        +--> select by runtime arch/platform/module context
        +--> rewrite original compiler command
        +--> compile one object
        +--> link injection dylib
        |
        v
InjectionNextRuntimeServer.loadDylib()
        |
        v
runtime patches loaded app/framework image
```

---

## 3. Compile Context 模型

当前实现中的 `CachedCommand` 保存：

```text
command
logPath
workingDirectory
platform
arch
module
targetTriple
debugConfiguration
```

### 当前身份模型

Cache key 已从单纯：

```text
source | platform
```

扩展为能区分 architecture/module 等上下文。

### 仍需增强的身份字段

设计目标还包括：

```text
workspace
project
target
configuration
```

当前代码还没有把这些都作为一等字段稳定提取，因此文档中不把它们标记为已完成。

---

## 4. Compiler Command 发现

### 4.1 Interception

优先读取：

```text
~/.agentInjectionIII/cache/frontend-commands.log
```

格式：

```text
<working-directory>\t<swift frontend command>
```

每条 command 解析：

- platform
- architecture
- module
- target triple
- primary files
- Debug 状态

一个 batch frontend command 可以为多个 `-primary-file` 建立候选。

### 4.2 Xcode activity log

Fallback 扫描：

```text
~/Library/Developer/Xcode/DerivedData/*/Logs/Build/*.xcactivitylog
```

或显式 `--derived-data` 指定路径。

扫描最近 build logs，寻找包含目标 source 的 Swift/Clang compile command。

### 4.3 Bazel

若 source 所在目录检测到 Bazel workspace，则继续复用 InjectionLite 的 Bazel provider。

---

## 5. Candidate Selection

目标不是：

```text
找到第一条 -> 使用
```

而是：

```text
collect all candidates
      |
      v
deduplicate same context
      |
      v
filter runtime platform
      |
      v
filter runtime arch
      |
      v
single candidate?
  |             |
 yes           no
  |             |
 use      same context?
                |
         +------+------+
         |             |
        yes           no
         |             |
        use       AMBIGUOUS
```

关键原则：

- 单候选保持原来零配置行为
- 多候选只在必要时启用更严格选择
- 不可靠时拒绝猜测

---

## 6. Swift Command 重写

原始 Xcode batch command 可能是：

```text
swift-frontend
  -frontend
  -c
  -primary-file Foo.swift
  -primary-file Bar.swift
  -primary-file Baz.swift
  Qux.swift
  -target arm64-apple-ios...
  -module-name Feature
  ...
```

注入 Foo 时：

```text
swift-frontend
  -frontend
  -c
  -primary-file Foo.swift
  Bar.swift
  Baz.swift
  Qux.swift
  ...
  -o /tmp/agentInjectionIII/<uuid>.o
  -DDEBUG
  -DINJECTING
```

这样：

- 只生成 Foo 的 object
- Bar/Baz/Qux 仍参与类型解析
- 保留原始 module / SDK / header map / framework search path 等环境

如果有 `-filelist`：

- filelist 已提供 secondary source context
- 其他 primary argument 可以整个移除

---

## 7. Objective-C Command 重写

ObjC / ObjC++ 不重建编译参数，只做最小修改：

1. 移除原 `-o`
2. 指向新的 object path
3. 添加：

```text
-DDEBUG
-DINJECTING
-Xclang -fno-validate-pch
```

这能够继续继承：

- `-I`
- header map
- module map
- ARC 设置
- deployment target
- SDK
- CocoaPods flags

---

## 8. Missing Input 恢复

Swift frontend command 可能引用已经被 Xcode 清理的临时文件。

当前实现已处理：

### filelist

若原 `-filelist` 已不存在：

1. 从 activity log 找相关 `-output-file-map`
2. 读取 output file map
3. 恢复 source list
4. 在 `/tmp/agentInjectionIII` 生成临时 filelist
5. 重写 compiler command

### PCH

若 bridging-header PCH 路径失效：

- 根据 PCH 文件名前后缀寻找当前有效版本
- 恢复后重试 compile

---

## 9. Activity Log Parser

Xcode 的 `.xcactivitylog` 不是纯文本。

实际内容可能出现：

```text
36"E0157793-..."026235...(20738"/Applications/Xcode.app/.../swift-frontend ...
```

旧 parser 仅以 whitespace 判断 executable 起点，可能得到：

```text
36"E015..."/Applications/.../swift-frontend
```

导致：

```text
zsh: unmatched "
```

当前修复将下列字符视为 executable token 边界：

- whitespace
- `"`
- `'`
- control characters
- binary serialization boundary

最终 command 必须从真实 absolute executable path 开始。

---

## 10. Compiler Interception

### 问题

Xcode 26.3+ 的 built-in Swift Driver 可能直接调用：

```text
swiftc
```

如果仅 patch `swift-frontend`，则 frontend command 可能不再被记录。

### 设计

interception patch 必须：

- 保存原始 compiler
- 安装 wrapper
- 保留 driver invocation semantics
- 记录 frontend compile commands
- patch/unpatch 可逆
- 不影响正常 Xcode build

---

## 11. Cache 与失败恢复

正常：

```text
lookup cached context
  -> compile success
```

缓存失效：

```text
cached compile fails
  -> invalidate
  -> rediscover once
  -> retry once
```

严格禁止递归无限重进整个入口。

之前观察到的失败模式：

```text
bad cache
 -> invalidate
 -> recursive compileAndLink()
 -> ingest same bad command again
 -> ...
 -> SIGSEGV / stack overflow
```

当前实现已经限制缓存重试次数。

---

## 12. Dylib Link

object 编译成功后，通过：

```text
xcrun --sdk <sdk> clang
  -arch <runtime-arch>
  -dynamiclib
  -undefined dynamic_lookup
  -dead_strip
  -Xlinker -interposable
  ...
  <object>
  -o <uuid>.dylib
```

生成注入 dylib。

compile command 中的 target triple 会尽量用于保持 deployment target 一致。

---

## 13. Dynamic Framework 热重载

对于：

```text
App
  -> SmokeFeature.framework
```

注入代码来自 Framework 时，需要同时满足：

1. 编译上下文来自 Framework target
2. module / arch 正确
3. Framework image 已加载到运行中的 App
4. Framework 自身 Debug link 支持 interposition

否则可能出现：

```text
dylib loaded
but rebound 0 symbols
```

后续 diagnostics 应进一步加入：

- runtime image lookup
- interposable 检测
- rebound count / no-effect 语义

---

## 14. Host Watcher 与 Runtime Watcher

AgentInjectionIII 自己的 watcher：

```text
ProjectFileWatcher
  -> pending only
```

InjectionLite standalone watcher：

```text
save
  -> auto compile/inject
```

后者不符合 Agent-first 模型。

因此 host 通过 `AgentInjectionHostShim` 提供 InjectionNext sentinel，确保链接 InjectionLite 依赖时不会启动 standalone watcher。

Runtime build 也设置：

```text
INJECTION_NOSTANDALONE=1
```

并为上游早期 `+load` 路径增加 guard。

---

## 15. Diagnostics

`doctor SOURCE` 当前使用 runtime platform/arch 调用 compiler diagnostics。

当前可以看到：

- candidate count
- modules
- architectures
- ambiguous

统一 `diagnostics` 还会返回：

- backend status
- targets
- trace state
- compiler state
- doctor
- logs
- events
- last error

这让 Agent 可以先诊断再决定是否继续 inject。

---

## 16. 单工程兼容策略

任何增强都遵守：

```text
if candidates.count == 1:
    use it
else:
    resolve context
```

不会变成：

```text
必须 --target
必须 --module
必须人工配置
```

简单项目不感知复杂项目逻辑。

---

## 17. 测试架构

### Unit

覆盖：

- Swift command rewrite
- quoted source path
- filelist path
- arch selection
- module ambiguity
- activity-log binary prefix
- bounded cache retry
- interception patch/unpatch

### Simulator Smoke

```text
SimulatorSmokeApp.xcworkspace
├── App project
│   ├── Objective-C AppDelegate/Application
│   ├── Swift SmokeViewController
│   └── CocoaPods / Masonry
└── FeatureProject
    └── SmokeFeature.framework
        ├── SmokeFeature.swift
        └── 64 filler Swift files
```

验证：

```text
BEFORE -> AFTER
FEATURE_BEFORE -> FEATURE_AFTER
```

后续继续跑 screenshot/touch/trace/profile/call-order/instances，确保热重载改动没有破坏其他 AgentInjectionIII 能力。
