# AgentInjectionIII 统一排障流程

Agent 和开发者都使用同一套排障入口。

## 统一日志位置

所有持久诊断日志统一写入：

```text
~/Library/Logs/AgentInjectionIII/diagnostics.log
```

日志包含：

- injectiond 启动/退出与 singleton control-layer 信息
- Runtime 连接、断开、projectRoot、executable
- Runtime → Project 路由固定结果
- 编译/链接/签名/注入生命周期
- 编译与注入错误
- Trace/Runtime 组件通过 `AgentLogStore` 输出的诊断信息
- 依赖直接输出到 stdout/stderr 的信息

不再把持久诊断拆成多个日志文件。

## 保留策略

日志按“当前自然日”保留。

每次 injectiond 启动时：

1. 检查 `diagnostics.log` 的最后修改日期。
2. 如果不是今天，直接截断旧文件。
3. 如果仍是今天，继续追加。

因此 daemon 重启不会丢掉当天上下文，但前一天日志会在下一次启动时自动清除。

## Agent 首选命令

即使 injectiond 已经无法连接，下面的命令仍然可以读取日志：

```bash
injectionctl diagnostic-log 300
```

输出为 JSON：

```json
{
  "ok": true,
  "path": ".../Library/Logs/AgentInjectionIII/diagnostics.log",
  "lines": [
    "..."
  ]
}
```

## 固定排障顺序

### 1. 先检查 Control Layer

```bash
injectionctl status
```

如果失败，不要继续依赖 daemon API，直接：

```bash
injectionctl diagnostic-log 300
```

重点搜索：

```text
[daemon]
singleton
bind
runtime server
trace server
socket
error
```

### 2. daemon 可达，但设备没有连接

```bash
injectionctl targets
injectionctl diagnostics 100
injectionctl diagnostic-log 300
```

重点搜索：

```text
[runtime]
Runtime project root
Runtime executable
Runtime disconnected
[routing]
```

### 3. 设备已连接，但热重载失败

```bash
injectionctl last-error
injectionctl events 100
injectionctl diagnostics 100
injectionctl diagnostic-log 300
```

按生命周期定位：

```text
changed
compiling
compiled
signing
injecting
injected
failed
```

### 4. 多项目/多设备路由异常

统一日志会记录：

```text
[routing] Pinned runtime session to project.
```

结合：

```text
runtime id
runtime projectRoot
runtime executable
project id
project root
```

判断设备为何归属某个 Project。

一个已经连接并完成归属的 Runtime Session 在连接生命周期内不会因为新增 Project 被重新分配。

## 原则

- `diagnostics`：当前 daemon 的结构化快照。
- `last-error`：最近编译/注入错误。
- `events`：注入生命周期。
- `diagnostic-log`：当天完整持久上下文，也是 daemon 不可达时的兜底入口。

Agent Skill 应先按上述流程排障，不应自己启动第二个 injectiond。
