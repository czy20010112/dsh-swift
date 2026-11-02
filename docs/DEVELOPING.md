# 继续开发

这份文档回答"换一台机器、或者隔了一个月回来，怎么接着干"。
状态与缺口看 `PROGRESS.md`，取舍看 `DESIGN-NOTES.md`，坑看 `PITFALLS.md`。

---

## 1. 环境

| 需要什么 | 为什么 | 本机现状 |
|---|---|---|
| Swift 6.x（任意平台） | 三个核心库不依赖 UIKit，`swift test` 在哪都能跑 | Windows 上 Swift 6.4.1，`swift test` 约 2 秒 |
| Node 20+ | `Tools/*.mjs`，以及解码 zstd 夹具 | Node 24 |
| `@deepseek-ai/dsh` | 漂移检查要读实际安装的 host 包 | 全局装了 `0.2.1-rc.5` |
| Xcode + xcodegen | 只有 `App/` 需要在 Mac 上编译 | **本机没有 Mac**，靠 GitHub Actions |
| 越狱 iPhone + 能调它的设备代理 | 真机验收 | iPhone 13 / iOS 15.3.1 |

**没有 Mac 也没关系**：核心逻辑在本机秒级迭代，只有 `App/` 下的视图需要走 CI。
这也是 `DESIGN-NOTES.md` 第 1 条那条边界存在的原因。

---

## 2. 一分钟上手

```bash
cd dsh-swift
swift build          # 三个核心库
swift test           # 241 个测试，约 2 秒
node Tools/check-wire-drift.mjs   # 与已安装 host 包的常量对拍
```

`check-wire-drift.mjs` 的退出码有意义：

- `0` 一致；
- `1` 有漂移（**必须修**，否则运行时静默失效）；
- `2` 找不到 host 包（CI 里视为 skip，不算失败）。

出 iOS 包：推到 `main`，等 `Build IPA` workflow，然后

```bash
gh run download <run-id> -n dsh-swift-ipa
```

---

## 3. 代码地图

### L1 传输 `Sources/DshProtocol/`

| 文件 | 职责 |
|---|---|
| `WireConstants.swift` | host 侧常量的镜像：端点、cookie 前缀、28 条事件 allowlist、帧类型。**改它之前先跑漂移检查** |
| `Pairing.swift` | `/connect` 换发：URL 构造、403/401/409 分治、`Set-Cookie` 解析、cookie 名计算。传输层抽成 `Transport` 协议，尚未有 `URLSession` 实现 |
| `Hashing.swift` | 自带 SHA-256 与 base64url。不用 CryptoKit，因为它只在 Apple 平台有 |
| `PendingInteraction.swift` | 审批/提问的槽位状态机：ready 前拒收、排队、断代作废、`cancel` 三种语义 |

### L2 会话窗口 `Sources/DshSession/`

| 文件 | 职责 |
|---|---|
| `EventDecoder.swift` | 三代格式（v0/v3/v4）→ `SessionEvent`。坏行收集不抛错；未建模类型降级 `.unknown` |
| `SessionWindow.swift` | 按 seq 有序的窗口；`shadowed` 回答"被 replace 遮住了什么"，**从不删除** |
| `SurfaceRole.swift` | 每条事件是 transcript / modelOnly / compactionCheckpoint / notSurface |
| `AssistantStream.swift` | 压缩流展开：`dt` 比 `texts` 少一个，负 dt 钳 0 |

### L3 装配 `Sources/DshPresenter/`

| 文件 | 职责 |
|---|---|
| `ChatNode.swift` | 节点的全部类型与字段 |
| `TranscriptAssembler.swift` | 事件数组 → 节点 + 轮次骨架 + 队列。**跨事件关联都在这里** |
| `TurnStructure.swift` | 轮次/步骤边界、结束原因（五种） |
| `ReasoningAssembler.swift` | 思考块累加、收起摘要（字数/耗时） |
| `ToolAssembler.swift` | call/result 配对、三级卡、参数摘要优先级、8 KB 全文阈值 |
| `AssistantAssembler.swift` | 正文块组装、流式安全前缀、代码围栏检测 |
| `UserMessageFilter.swift` | 用户行白名单、`user-question-reply` 的 JSON 载荷解包 |
| `InboxQueue.swift` | 队列 splice 重放（**注意：节点尚未被装配器产出**） |
| `EventClassifier.swift` | 事件 → 有 UI 后果 / 会话头 / 元信息 / 流分片 / 结构 / 忽略 |
| `TextSummary.swift` | 一行截断（按字素簇）、紧凑字数与耗时 |

### 渲染与外壳 `App/`

| 文件 | 职责 |
|---|---|
| `NodeViews.swift` | 每种节点一个视图。**不做任何判断**，全部调 presenter |
| `TranscriptScreen.swift` | 列表 + 样例会话加载 |
| `ContentView.swift` | 首页：样例入口 + 库链接自检读数 |
| `Resources/sample-session.json` | 与 `Tests/Fixtures/v4-01.json` 同一份，有测试钉住 |

### 工具

| 文件 | 职责 |
|---|---|
| `Tools/check-wire-drift.mjs` | 常量与事件表对拍。**上游升级后第一个要跑的** |
| `Tools/export-fixtures.mjs` | 从本机会话导夹具。脱敏：跨分片拼接后再匹配、私人标识从环境变量读、写盘自检 |

---

## 4. 契约与它们的测试

改动任何一条之前，先看对应测试在锁定什么。

| 契约 | 违反后的症状 | 测试 |
|---|---|---|
| cookie 名 = `dsh-auth-` + b64url(sha256(authority))，authority 含端口 | 所有请求 401，且看起来像 token 过期 | `CookieNameTests` |
| `interactions` 不显式传就是 `none` | App 能连、流正常、**审批永远答不上且不报错** | `InteractionSlotTests` |
| `cancel` 帧区分不了"别人答了"和"上游撤回" | 自己点完也提示"已失效" | `InteractionSlotTests` |
| seq 必须是 `Double` | 实时内容全部塌到同一位置 | `SessionWindowTests` |
| `replace` 不删除对话记录 | 压缩一次抹掉上千条历史 | `SurfaceRoleTests`、`ReplayTests` |
| `dt.count == texts.count - 1` | 整条 run 的时间戳偏移一格 | `AssistantStreamTests` |
| `user/message` 只有 29% 是真人 | 假用户气泡刷屏 | `UserMessageFilterTests` |
| 工具按 `callId` 配对，不靠顺序 | 结果挂到别的卡上 | `ToolAssemblerTests` |
| 未知事件忽略、不报错 | 一种新插件事件让整个会话打不开 | `EventClassifierTests` |
| 事件 allowlist 共 28 条 | 少一条就收不到对应通知 | `check-wire-drift.mjs` |
| App 样例与夹具一致 | 真机验收的数据和测试验证的数据不是同一份 | `TranscriptReplayTests.testAppSampleMatchesFixture` |

---

## 5. 常见任务

### 上游发了新版本

```bash
npm i -g @deepseek-ai/dsh@latest
node Tools/check-wire-drift.mjs     # 看常量与事件表有没有漂
swift test
```

漂了就先改 `WireConstants.swift`，**再**去看有没有新事件需要建模（`EventClassifier`）。
夹具不用重导——它们来自会话数据，不是 host 包。

### 新增一种节点

顺序固定，漏一步就会出"定义了但永不显示"的问题（`PITFALLS.md` 第 38 条）：

1. `ChatNode` 加 case 与结构体；
2. `EventClassifier` 标注该事件的后果；
3. `TranscriptAssembler` 里产出它（以及跨事件关联）；
4. `App/Sources/NodeViews.swift` 加视图（只调 presenter）；
5. 单测：用手写事件序列验证；
6. **回放测试：断言某份夹具确实产出了它**——这条最容易漏，也最有价值。

### 重新导出夹具

需要本机的原始会话（`~/.dsh/sessions`），它们**不在仓库里**。

```bash
export DSH_FIXTURE_PRIVATE_DOMAINS="..."   # 私有域名，逗号分隔
export DSH_FIXTURE_PRIVATE_TERMS="..."     # 真名/账号等片段
node Tools/export-fixtures.mjs --max 15
cp Tests/Fixtures/v4-01.json App/Resources/sample-session.json
swift test        # 一致性测试会红，如果忘了同步
```

脚本自带 denylist 自检，命中就以退出码 1 失败。**不要绕过它。**

### 改装配规则

先写单测（`TranscriptAssemblerTests` 用手写事件序列把规则单独钉住），
再跑 `TranscriptReplayTests` 看 15 份真实会话有没有坏。两层缺一不可：
单测能定位是哪条规则坏了，回放能发现单测没想到的组合。

### 出包并在真机验收

```bash
git push                                   # 触发 Build IPA
gh run list --workflow build-ipa.yml
gh run download <run-id> -n dsh-swift-ipa
# 用设备代理把 IPA 装上去（设备地址与工具在私有笔记里，不进公开仓库）
```

**第一步永远是查设备是否锁屏**。锁屏时所有交互/安装类工具会被拦，
`wake_and_home` 只能唤到解锁提示，输不了密码——需要人工解锁（`PITFALLS.md` 第 39 条）。

`App/` 刻意不放进 SwiftPM 包，因为它依赖 SwiftUI，一旦进来本机就跑不了测试。单独构建：

```bash
xcodegen generate
xcodebuild -project DshApp.xcodeproj -scheme DshApp \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
```

---

## 6. 什么不在仓库里，为什么

| 东西 | 位置 | 原因 |
|---|---|---|
| 原始会话（326 个 / 523k 事件） | 本机 `~/.dsh/sessions` | 体积大，且含真实路径、私人域名；夹具是它的脱敏切片 |
| 设计评审与数据报告 | 私有工作区 | 含内网地址、工时估算、对私有仓库的逆向细节 |
| 数据分析脚本 | 私有工作区 | 要读原始会话才能跑；结论已写进 `PROGRESS.md` |
| 设备与 host 的具体地址 | 私有笔记 / 上层工作区脚本 | 公开仓库不放内网地址 |

夹具和 `recorded` 结论都在仓库里，所以**只 clone 这个仓库也能跑全部测试**。

---

## 7. 术语

| 词 | 意思 |
|---|---|
| **surface** | 模型看到的上下文。`replace` 只作用于它 |
| **transcript** | 人看到的对话记录。只由 `append` 来源构成，被遮蔽的内容照常显示 |
| **waterfall** | 需要客户端答复的事件。28 条 allowlist 里只有 2 条（审批、提问） |
| **peer** | 一次 `/connect` 换发得到的身份。凭证的寿命绑在它的 socket 上 |
| **dense index** | `assistant-stream` 帧的块序号，必须严格 +1；失配只能重开流 |
| **rebaseline** | 重开流并用新快照重建窗口。没有 cursor 可以带 |
| **durable / live chunk** | 落盘事件 / 实时合成事件（带小数 seq） |
| **projection** | 由事件派生的只读状态（上下文占用、待办、目标） |
