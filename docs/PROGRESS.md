# 进度

> 每次动完代码更新这份文档。设计决策记在 `DESIGN-NOTES.md`，踩过的坑记在 `PITFALLS.md`。
> 最后更新：2026-11-02。

## 当前状态

**241 个测试，全绿**（`swift test` 在本机 Windows 上跑，约 2 秒）。
CI 三个 job 全通：`test-linux` / `wire-drift` / `build-ios`；另有独立的 `Build IPA` workflow。

**App 已经能在真机上跑并渲染一份真实会话**（2026-11-01 验收，见下）。
但它还连不上真 host —— 配对、mux、`session.follow`、`$events` 订阅这四段都还没接。

| 模块 | 已完成 | 测试数 |
|---|---|---|
| `DshProtocol` | 线协议常量镜像（28 条事件）、`/connect` 配对逻辑、403/401/409 分治、SHA-256 + base64url、待决交互状态机 | 27 |
| `DshSession` | 会话窗口（seq 排序、live chunk 退役）、surface/transcript 分离、压缩流展开、三代格式解码 | 50 |
| `DshPresenter` | 节点模型、轮次骨架、思考块、工具、正文/Markdown、用户行白名单、排队队列、事件分类、端到端装配 | 164 |
| `App/`（不在 SwiftPM 包内） | 外壳、渲染层、离线样例回放 | 无测试，只验证编译 + 真机 |

### 一句话说清现在能干什么

打开 App → 看到一份打包好的真实会话被完整渲染成对话：用户发言、收起的思考行
（可展开）、工具卡（可展开、大结果走全文页）、待办、重试、斜杠命令、压缩标记、
交付物清单、带行内格式的正文。**但它是离线回放，不是连 host。**

---

## 阶段计划

远程档先行，设备内核在后。理由：远程档每一步只依赖一台跑着 `dsh web` 的机器，
零环境风险；先做 iSH 的话，一旦卡在内核级 bug 上，UI 一行都写不出来。

| 阶段 | 内容 | 状态 |
|---|---|---|
| **P0 配对** | `/connect` 换发、403/401/409 分治、Keychain、两级重连 | **协议逻辑完成**（`PairingClient` + 交互状态机）。缺 `URLSession` 传输实现、Keychain 存储、配对 UI。**这三项不完成就一行真数据都拿不到** |
| **P1a 流** | mux WebSocket、`session.follow`、dense index、rebaseline、分页 | 压缩流展开与三代解码完成；**mux 与 follow 未开始** |
| **P1b 装配器** | 19 类节点 → 实际 8 类 + 装配 | ✅ **完成**（九步，过程分组经实测取消） |
| **P1c 交互** | `$events` 生命周期、waterfall 双向、待决交互槽 | **状态机完成**（18 个测试）；流订阅与回包未接 |
| **P1d 壳层** | 会话列表、工作区、设置 | 未开始 |
| **P1e 渲染** | 节点视图、Markdown、展开/全文 | ✅ **第一版完成并真机验收**（离线数据） |
| **P2 iSH 内核** | submodule 升级、四处 flag 注入对齐、AOT 录制进 CI | 未开始，**范围已重估**（见下） |

### P2 的范围被调研改写了

原计划以为是"改 `exec.c` 的两个常量"。实测后不成立：

- flag 注入有**四处**，宿主侧（`ISHKernel.m`、`ISHShellExecutor.m`）两处在不同路径生效，
  只改 `exec.c` 看起来"没生效"；
- 单独去掉 `--jitless` 会把 Sparkplug/Maglev/TurboFan 全打开，回到当初加它要规避的问题；
  上游的"默认模式"同时加了 `--no-sparkplug --no-maglev --no-opt`；
- 把堆放到 1GB 会让 OOM 从"V8 自己 abort"变成"整 App 被 jetsam 杀、会话一起丢"，
  因为当前 pin 的版本里内核匿名页上限形同虚设（上游收紧的三个提交都不在）；
- 真正的提速手段是 **AOT 映像**（1.4x–3.9x），不是关 jitless（上游实测仅 10%）；
- 配置化路径（`ISH_NODE_MODE`）只在上游一个分支，没进 master；本地 submodule
  **落后 master 62 个提交**。

细节见 `PITFALLS.md` 第 18–22 条，决策见 `DESIGN-NOTES.md` 第 10 条。

### P1b 的九步（按"覆盖的事件占比"排）

覆盖率依据：326 个真实会话 / 523,473 条事件的全量统计。

| 步 | 内容 | 覆盖事件 | 状态 |
|---|---|---|---|
| 1 | 骨架：`turn/step` 边界 + 窗口 | 15.8% | ✅ |
| 2 | **思考块**：`reasoning-chunks` 累加 + 收起摘要 | **44.3%** | ✅ |
| 3 | **工具**：call/result 按 callId 配对 + 三级卡 | 18.3% | ✅ |
| 4 | 正文：`assistant/message` + Markdown | 12.4% | ✅ |
| 5 | 用户行：白名单过滤 | 0.7% | ✅ |
| 6 | inbox：`agent/inbox/spliced` | 0.9% | ✅ 解码与队列重放；**节点未产出**（见缺口 2） |
| 7 | ~~过程分组~~ | — | **取消**（实测 81.3% 的连续工具段只有 1 个调用） |
| 8 | 压缩流 + `surfaceOp.replace` | — | ✅ |
| 9 | 长尾与未知事件降级 | 1.6% | ✅（夹具上占位节点 0） |

---

## 真机验收记录（2026-11-01）

设备 iPhone 13 / iOS 15.3.1（Dopamine rootless），走 ios-mcp 安装启动。

| 项 | 结果 |
|---|---|
| 安装包 | `dsh-swift-5bca7e7-unsigned.ipa`，404,341 字节，ad-hoc 签名 |
| bundle id / 名称 | `io.github.dshswift.app` / 显示名 `dsh`，版本 0.1.0，minOS 15.0 |
| 启动 | 正常，前台确认 |
| 首页读数 | 转发事件 **28**、需答复 **2**、surface 类型 **5**、已建模事件 **41** —— 与代码一致，说明三个库都链接进来了 |
| 样例会话行 | "事件 161 → 节点 60"，与 Windows 上回放结果一致 |
| 正文渲染 | 用户气泡、思考行「思考 0.6 秒 · 97 字」、工具卡（绿勾 + 参数摘要 + 结果摘要）、待办「0/6」、重试「1/5 · 连接中断」、命令「/compact」、压缩分隔、交付物清单、正文粗体 |
| 交互 | 点思考行可展开全文（截图确认） |
| 滚动 | 正常，`LazyVStack` 无卡顿观感 |

截图：`D:\AI\OpenMinis-iOS-dev\shots\dsh-swift-transcript-1.jpg`（中部）、
`dsh-swift-transcript-top.jpg`（顶部）、`dsh-swift-expand-reasoning.jpg`（展开后）。

**这次验收证明的是渲染层**，不是端到端连 host。

---

## 已知缺口（按"挡住下一步的程度"排）

### 高：不补齐就永远拿不到真数据

1. **配对没有传输实现**。`PairingClient` 只定义了 `Transport` 协议和解析逻辑，
   没有 `URLSession` 版本、没有"不跟随重定向"的实现、没有 Keychain 存储、没有 UI。
2. **mux 未实现**。`/api/remote.mux` 的 WebSocket 收发、`exactKeys` 严格序列化、
   30 秒无帧判死、重连两级回退，全部未写。
3. **`session.follow` 未实现**。snapshot / 增量 / assistantStream 帧、revision 断档、
   rebaseline、`turnWindow` 分页，全部未写。
4. **`$events` 未订阅**。交互状态机有了，但没有任何代码去开这条流、把 ready / waterfall /
   cancel 帧喂给它，也没有把答复 POST 到 `/api/$events/result`。

### 中：功能在，但用户看不到

5. **`turnTail` 节点从未产出**。`assistant/message.usage` 已解码，但装配器不生成节点，
   所以 token 用量、耗时、上下文占用在界面上完全没有。
6. **`inbox` 节点从未产出**。`TranscriptAssembler` 把 splice 重放进了 `InboxQueue`，
   但**没有调用 `queue.nodes(seq:filter:)`**，App 也没显示队列 —— 排队中的输入完全不可见。
   `grep "inbox.nodes\|\.nodes(seq"` 在 `Sources/` 与 `App/` 里零命中。
7. **轮次骨架没被 UI 使用**。`TurnStructure` 算出来了，但没有整轮折叠、没有轮次边界、
   没有"停止"按钮。单轮 p90 有 684 个事件，不折叠会很累。
8. **流式未接**。`isStreaming` 在离线装配里恒为 false。实时增量、rebaseline 的重放都没做。
9. **性能未测**。首帧、滚动帧率、内存峰值一个数都没有。

### 低：已知但不挡路

10. **参数解析失败时卡片直接显示原始 JSON**。真机上看到部分 `pwsh` 卡显示
    `{"command":"$env:HTTPS_PROXY=…`，原因是夹具把长字符串截断到 2 KB 破坏了 JSON；
    真实会话 47,955 次调用**零个非法 JSON**，所以这是夹具产物。但它暴露一个 UX 缺口：
    `.raw` 档应该至少尝试正则提取 `description`/`command`，而不是整坨 JSON。
11. **代码围栏渲染未在截图上确认**。样例里有 1 处三反引号，没有被拍到。
12. **App 无测试**。`App/` 下的视图只有编译验证，没有 UI 测试。

---

## 卡点（外部条件，不是代码问题）

| 卡点 | 影响 | 现状 |
|---|---|---|
| **没有 Mac** | `App/` 下任何 SwiftUI 改动只能靠 CI 编译，一轮约 3 分钟（CI 1 分 + 下载 + 安装） | 已接受；核心三层在 Windows 上跑测试，绕开了大部分往返 |
| **设备锁屏需人工解锁** | 锁屏时 ios-mcp 拦掉所有交互/安装类工具；1.2.7 没暴露解锁工具 | 每次验收前用 `wake_and_home`；若仍 locked 须人工 |
| **host 没在跑** | 远程档的"真连"一步都测不了 | 本机装了 `@deepseek-ai/dsh@0.2.1-rc.5`；未起 `dsh web`，未配 `trustedHosts` |
| **iOS 26 线暂缓** | 后台保活（M6/P4）在这台 iOS 15 设备上无法验收 | 用户决定：先在 iOS 15 上把功能验收完 |
| **iSH P2 规模** | 62 个提交的升级 + 四处注入 + AOT 306 MB | 按计划排在远程档可用之后 |

---

## 数据基线

所有"该做什么、做到什么程度"的判断都来自这组实测，不是猜的。扫描脚本在私有工作区
（不在本仓库，因为它要读本机的真实会话）。

| 指标 | 数值 |
|---|---|
| 样本 | 326 个会话 / 523,473 条事件 |
| 事件类型 | 54 种（另两份样本 47 / 39 种 → 词表随插件漂移） |
| `reasoning-chunks` | 231,948 条，**占全部事件 44.3%** |
| 正文体积构成 | reasoning 57.2 MB / 工具结果 98.3 MB / 工具参数 38.8 MB / **assistant 正文仅 3.5 MB** |
| `user/message` 真人占比 | **28.9%**（1,005 / 3,474），其余 18 种来源都是注入 |
| 工具种类 | 60 种，前 5 个占 **88.1%**（pwsh 53.9%） |
| 工具结果长度 | p50 421 / p90 5,292 / p99 27,437 / max 128,705 字符 |
| 工具参数长度 | p50 386 / p99 7,835 / max 76,093 字符 |
| 单轮事件数 | p50 107 / p90 684 / p99 6,431 / max 15,698 |
| 单会话事件数 | p50 601 / p90 4,316 / max 48,603 |
| `surfaceOp.replace` | 152 次（只遮蔽模型上下文，不删对话记录） |
| `agent/inbox/spliced` | 4,585 次（**比真人发言还多**） |
| 会话格式代际 | v0 58 个 / v3 31 个 / v4 268 个（**三代，不是两代**） |
| Markdown 用量 | 行内代码 34.4%、粗体 29.6%；任务列表与 LaTeX **零出现** |
| 连续工具段 | 81.3% 只有 1 个调用，p99=3，max=8 → 不做分组 |

---

## 回放基础设施

- `Tools/export-fixtures.mjs`：从本机会话挑样本、脱敏、导出夹具。私人标识从环境变量读
  （`DSH_FIXTURE_PRIVATE_DOMAINS` / `DSH_FIXTURE_PRIVATE_TERMS`），写盘后自检，命中即退出码 1。
- `Tests/Fixtures/`：15 个夹具（v4 8 / v0 4 / v3 3），1.6 MB，覆盖全部 53 种事件类型。
- `Sources/DshSession/EventDecoder.swift`：三代格式都能解，未知类型降级 `.unknown`，坏行收集不抛错。
- `Tests/DshSessionTests/ReplayTests.swift`：13 个回放测试，解码 0 失败。
- `Tests/DshPresenterTests/TranscriptReplayTests.swift`：12 个（11 个端到端回放断言 + 1 个
  App 样例与夹具一致性）。

---

## 端到端装配（`TranscriptAssembler`）

事件数组 → `[ChatNode]` + 轮次骨架 + 排队队列。整窗重算，不做增量。

15 个真实夹具上的结果：

| 指标 | 数值 |
|---|---|
| 工具调用拿到结果 | 239 / 243（98%），差的 4 个全在 v3（host 丢过事件） |
| 有时长的思考块 | v0 11 / v3 47 / v4 74 —— 三代都能算出时长 |
| 压缩标记 | 1 个，标记前的历史完整保留 |
| 占位节点（unknown） | 首版 156 个 → **0 个** |

关键的衔接规则：

- **v0 的思考分片在消息之前**（独立顶层行）；v3/v4 嵌在消息的 `stream` 里。
  两种都归到下一条 `assistant/message`；
- **正文以 `message.content` 为准**，流分片只用来算思考时长（content 里没有 dt）；
- **消息里的 tool-call 块不出节点**，以同一次调用的 `tool/call` 事件为准，否则显示两张卡；
- **被重试作废的生成（`assistant/attempt`）清空攒下的思考**；
- **连续重试只留最新一条**；新一轮从 1 重新开始时另起节点；
- **斜杠命令的 run 与 done 按 commandId 合成一个节点**；run 不在窗口时也要显示结果。

---

## App 外壳与 IPA 流水线

- **工程**：`project.yml`（XcodeGen）生成工程，`.xcodeproj` 不入库。target `DshApp`，
  bundle id `io.github.dshswift.app`，iOS 15.0，SwiftUI 生命周期，显示名 `dsh`。
  通过根目录的本地包依赖三个核心库；**界面代码只在 `App/` 下**。
- **渲染层**：`App/Sources/NodeViews.swift` + `TranscriptScreen.swift`。视图只负责画，
  摘要/截断/白名单全部在 `DshPresenter` 里（有测试）。只用 iOS 15 已有的 API。
- **样例会话**：`App/Resources/sample-session.json`，与 `Tests/Fixtures/v4-01.json` 同一份；
  有测试断言两份逐字节一致，防止真机验收的数据和测试验证的数据漂移。
- **Info.plist**：`NSLocalNetworkUsageDescription`；ATS 只开 `NSAllowsLocalNetworking`。
- **流水线**：`.github/workflows/build-ipa.yml`，push main 或手动触发。macos-14，
  `CODE_SIGNING_ALLOWED=NO` 编译 → ad-hoc 签名（`codesign -s -`，不带 entitlements）→
  `dsh-swift-<short-sha>-unsigned.ipa`，artifact 名 `dsh-swift-ipa`，保留 14 天。
- **CI 修复**：`ci.yml` 的 `build-ios` 曾有两个静默失败（Xcode 版本落错、管道吞退出码），
  已修，见 `PITFALLS.md` 第 35、36 条。现在真的用 Xcode 16.2 编译。

---

## 下一步（建议顺序）

1. **P0 收口：让 App 真连上一台 host。**
   起 `dsh web --port 3080 --no-open`，配 `trustedHosts`；补 `URLSession` 传输（不跟随重定向）、
   Keychain 存储、手动输入 baseUrl + token 的配对页；用 `GET /api/...` 拉一次
   `session.list` 证明 cookie 能用。**这一步是分水岭**，之前所有验收都是离线数据。
2. **P1a：mux + `session.follow` 最小闭环。** 先只消费 snapshot 与 durable 事件，
   渲染与离线回放同一套装配链；`assistantStream` 增量与 rebaseline 放第二步。
3. **补两个"功能在但看不见"的缺口**：产出 `turnTail`（用 `assistant/message.usage`）、
   把 `InboxQueue.nodes()` 接进装配结果并显示在输入框上方。
4. **轮次折叠**（用已有的 `TurnStructure`）+ **流式**（`isStreaming` 接真）。
5. **P1c：`$events` 订阅 + 审批闭环。** 与电脑浏览器同时在线，验证"谁先点谁生效"。
6. 之后才是壳层（会话列表/设置）、性能测量、P2 内嵌档。
