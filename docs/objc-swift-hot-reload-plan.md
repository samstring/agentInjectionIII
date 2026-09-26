# ObjC + Swift 多工程热重载工作入口

分支：`feature/objc-swift-hot-reload`

本文件作为本分支文档入口。详细内容拆分为：

- [需求文档](./objc-swift-hot-reload-requirements.md)
  - 为什么要做
  - 支持范围
  - 兼容性要求
  - diagnostics / cache / batch Swift 要求
  - E2E 验收标准

- [技术设计文档](./objc-swift-hot-reload-architecture.md)
  - Agent -> daemon -> compiler -> runtime 架构
  - compile context 模型
  - compiler command discovery / selection
  - Swift batch rewrite
  - activity-log parser
  - cache retry
  - dynamic Framework / interposable
  - diagnostics 与测试架构

- [实现文档](./objc-swift-hot-reload-implementation.md)
  - 当前代码文件映射
  - 已实现能力
  - 已解决问题
  - 当前 CI blocker
  - 尚未完成的多工程 Framework E2E
  - 后续实现顺序

## 当前目标

```text
Workspace
├── App.xcodeproj
│   ├── Objective-C
│   └── Swift
└── FeatureProject.xcodeproj
    └── SmokeFeature.framework
        ├── SmokeFeature.swift
        └── many Swift sources

FEATURE_BEFORE
   -> edit
   -> explicit inject
FEATURE_AFTER
```

要求：

- 不 rebuild App
- 不 reinstall App
- 不 relaunch App
- 单工程保持零额外配置
- 多工程发生歧义时不允许猜测
- 保存源码只进入 pending，不自动注入

## 完成标准

```text
swift build                       ✅
swift test                        ✅
MCP                               ✅
InjectionIII compatibility        ✅
Menu App                          ✅
ObjC + Swift + CocoaPods          ✅
App Swift BEFORE -> AFTER         ✅
Large Swift target                ✅
Multi-project Swift Framework     ✅
FEATURE_BEFORE -> FEATURE_AFTER   ✅
```

以上全部通过后，本分支才算完成。
