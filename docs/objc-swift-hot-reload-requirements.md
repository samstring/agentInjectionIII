# ObjC + Swift 多工程热重载需求文档

分支：`feature/objc-swift-hot-reload`

## 1. 背景

AgentInjectionIII 已经能够在 Simulator 中完成基础 Swift 单文件热重载，并且现有 Smoke App 已覆盖 Objective-C + Swift + CocoaPods。

大型 iOS 工程通常还会包含：

- 一个 `.xcworkspace` 下多个 `.xcodeproj`
- 多个 App / Framework / Module / Target
- Objective-C 与 Swift 混编
- CocoaPods、SPM 或本地动态 Framework
- 数百到数千个 Swift 源文件
- 同一源文件可能出现在不同架构、模块或构建上下文中
- Xcode 新版本对 Swift Driver / `swiftc` / `swift-frontend` 调用链的变化

这些条件会放大原有“按源码路径找到一条编译命令并重编”的不确定性。

本分支的目标是：**在不增加简单项目使用成本的前提下，让大型、多工程、ObjC + Swift 混编项目中的 Swift 热重载可靠、可诊断、可验证。**

---

## 2. 核心目标

### 2.1 单工程保持零配置

对于只有一个有效编译上下文的源文件：

```text
Foo.swift
  -> 唯一 compile context
  -> 直接编译并注入
```

不得要求开发者额外指定：

- target
- module
- project
- workspace
- architecture

现有简单项目行为必须保持兼容。

### 2.2 多工程必须精确选择编译上下文

对于存在多个候选编译命令的源文件，AgentInjectionIII 必须根据运行时与编译上下文进行筛选，不能简单使用“最新一条”或“第一条”。

最低需要考虑：

- source path
- platform
- runtime architecture
- Swift module
- target triple
- Debug / 非 Debug
- build-log / interception 来源
- working directory

后续需要继续增强：

- target identity
- project identity
- workspace identity
- configuration identity

### 2.3 不允许静默猜测

如果多个不同编译上下文仍无法消歧：

```text
Shared.swift
  -> FeatureA / arm64
  -> FeatureB / arm64
```

必须返回明确的 ambiguity 错误，而不是随便选一条并报告“注入成功”。

### 2.4 支持大量 Swift 文件

Swift target 中存在大量源文件时，单次热重载仍应只生成当前被修改文件对应的 object：

```text
Foo.swift
  -> Foo.o
  -> injection dylib
```

同时必须保留同 batch 其他 Swift 文件作为 secondary source，使当前文件仍能完成类型解析。

### 2.5 支持 ObjC + Swift 混编

必须继续支持：

- `.swift`
- `.m`
- `.mm`
- `.cpp`
- `.cc`
- `.cxx`

Swift 编译必须尽量复用原始 Xcode frontend command，从而保留：

- `-import-objc-header`
- module map
- header map
- `-I`
- `-F`
- Swift explicit modules
- deployment target
- SDK
- compiler feature flags

Objective-C / Objective-C++ 也必须继续复用原始 compile flags。

### 2.6 多工程动态 Framework 必须可热重载

需要覆盖：

```text
Workspace
├── App.xcodeproj
│   ├── Objective-C
│   └── Swift
└── FeatureProject.xcodeproj
    └── SmokeFeature.framework
        ├── SmokeFeature.swift
        └── many Swift sources
```

运行 App 后修改 Framework 内的 Swift 文件：

```text
FEATURE_BEFORE
   -> edit
   -> explicit inject
FEATURE_AFTER
```

期间不得：

- rebuild App
- reinstall App
- relaunch App

### 2.7 动态 Framework / Package 必须满足 interposition 条件

动态 Framework、动态本地 Package 等独立 image 内的 Swift symbol replacement 依赖其自身链接设置。

Debug 构建需要支持或明确诊断：

```text
-Xlinker -interposable
```

不能只给主 App 配置而假设所有 Framework 都自动可替换。

---

## 3. Agent 控制模型

AgentInjectionIII 的控制模型必须保持：

```text
source save
   -> watcher records pending
   -> no automatic injection

AI Agent / Menu / CLI / MCP / Control + -
   -> explicit inject
```

项目 watcher 只能收集 pending source，不允许因为保存文件自动编译或注入。

这也是与传统 InjectionIII 自动 watcher 模式的重要区别。

---

## 4. Compiler Command 来源

系统需要支持多种编译命令来源，并按可靠性使用：

1. compiler interception 捕获的真实 frontend command
2. Xcode `.xcactivitylog`
3. Xcode build output
4. Bazel provider

编译命令读取必须能够处理 Xcode 结构化日志中的二进制/序列化前缀，不能把前缀字节误认为 executable 的一部分。

---

## 5. Cache 需求

### 5.1 不再只使用 source + platform 作为身份

旧模型：

```text
source | platform
```

不足以区分大型工程中的不同上下文。

Cache 至少需要容纳：

```text
source
platform
arch
module
targetTriple
debugConfiguration
workingDirectory
logOrigin
```

### 5.2 缓存失败必须可恢复

缓存命令失败时：

1. invalidate 对应缓存
2. 最多重新发现并重试一次
3. 第二次失败直接返回真实错误

禁止形成：

```text
bad cache
 -> retry
 -> ingest same bad cache
 -> retry
 -> ...
```

从而导致 stack overflow / SIGSEGV。

---

## 6. Swift Batch 编译需求

对于：

```text
-primary-file Foo.swift
-primary-file Bar.swift
-primary-file Baz.swift
Qux.swift
```

注入 `Foo.swift` 时应重写为：

```text
-primary-file Foo.swift
Bar.swift
Baz.swift
Qux.swift
```

即：

- Foo 保持唯一 primary
- Bar / Baz 降级为 secondary source
- secondary source 参与类型检查，但不生成额外 object

如果原命令使用 `-filelist` 提供完整 source list，则其他 primary argument 可以移除。

---

## 7. Xcode 版本兼容

### 7.1 Xcode 26.3+

需要处理 Swift Driver 直接调用 `swiftc`、绕过 `swift-frontend` wrapper 的情况。

Compiler interception 必须：

- 不破坏正常 Swift Driver 语义
- 可捕获 frontend compile context
- patch / unpatch 可逆
- fallback 到 build log 时仍可工作

### 7.2 Activity Log

`.xcactivitylog` 中可能存在：

```text
<binary metadata>"/Applications/Xcode.app/.../swift-frontend ...
```

parser 必须从真实 executable path 开始截取。

---

## 8. Diagnostics 需求

`doctor SOURCE` 至少需要提供：

- source 是否存在
- runtime platform
- runtime arch
- build system
- compile command 是否找到
- candidate 数量
- module 列表
- architecture 列表
- ambiguity 状态

目标诊断格式：

```text
source             ✅
workspace          MyApp.xcworkspace
project            Feature.xcodeproj
target             Feature
module             Feature
configuration      Debug
platform           iPhoneSimulator
arch               arm64
compiler context   ✅
runtime image      Feature.framework ✅
interposable       ✅
```

其中 workspace/project/target/runtime-image/interposable 的完整自动识别仍属于后续增强项。

---

## 9. 兼容性要求

### 单工程

- 无新增配置
- 无需手动指定 module / target
- 行为和原来一致

### InjectionIII

- 未安装 AgentInjectionIII 的团队成员仍能使用传统 InjectionIII
- Agent runtime 为 opt-in
- 不破坏 InjectionIII 原有接入方式

### Main 新功能

必须兼容当前 `main` 已有能力：

- AgentInjectionIII Menu Bar App
- pending source watcher
- `Control + -`
- `inject-pending`
- unified diagnostics
- device trace
- daemon lifecycle
- signing identity refresh

---

## 10. 性能要求

Swift 文件数量增加时允许 compile frontend 初始化变重，但不应因为文件数量线性扫描所有 DerivedData build logs 于每一次注入。

目标：

```text
首次：
build logs / intercepted command
  -> index/cache

后续：
source
  -> candidate lookup
  -> compile
```

大型项目优化重点：

- 避免重复解压和全量扫描 activity logs
- 避免错误候选导致重复编译
- 尽量命中 captured compile context

---

## 11. 失败语义

必须区分：

- `SOURCE_NOT_FOUND`
- `UNSUPPORTED_SOURCE`
- `COMPILE_COMMAND_NOT_FOUND`
- `COMPILE_COMMAND_AMBIGUOUS`
- `FILELIST_MISSING`
- `COMPILE_FAILED`
- `LINK_FAILED`
- runtime load / patch failure

Agent 应拿到真实原因，而不是统一返回“热重载失败”。

---

## 12. 验收标准

### 必须通过

- `swift build`
- `swift test`
- MCP syntax / transport
- InjectionIII compatibility smoke
- macOS Menu App build
- Simulator smoke

### Simulator E2E

必须观察真实行为变化：

```text
App Swift:
BEFORE -> AFTER

Second xcodeproj Swift Framework:
FEATURE_BEFORE -> FEATURE_AFTER
```

不能只检查：

```json
{"compiled": true, "injected": true}
```

必须验证已经运行中的 App 行为确实发生改变。

---

## 13. Definition of Done

本分支完成条件：

1. 已同步最新 `main`
2. 简单单工程路径无回归
3. ObjC + Swift + CocoaPods 继续可用
4. 大型 Swift batch compile context 正确
5. 多 arch/module 不误选
6. activity-log command parser 稳定
7. 第二个 xcodeproj 的 Swift Framework 可在不 rebuild/relaunch 的情况下完成 `FEATURE_BEFORE -> FEATURE_AFTER`
8. CI 全绿
