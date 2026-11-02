# dsh-swift

DeepSeek Harness 的原生 iOS 客户端。手机连上一台跑着 `dsh web` 的机器，看它思考、
看它调工具、在外面批准它要做的事。

目标设备是 **iPhone 13 / iOS 15.3.1**（当前唯一在册的实测机）。构建走 GitHub Actions，
验收走 ios-mcp。

---

## 这个仓库现在有什么

**能做的事**：装到 iPhone 上，打开 App，看到一份打包好的真实会话被完整渲染成对话——
用户发言、可展开的思考行、工具卡（大结果走全文页）、待办、重试、斜杠命令、压缩标记、
交付物，以及带行内格式的正文。**它还是离线回放，连不上真 host**：配对、mux、
`session.follow`、`$events` 订阅都还没接。

| 模块 | 层 | 状态 |
|---|---|---|
| `DshProtocol` | L1 传输：配对换发、线协议常量、SHA-256/base64url、`$events` 待决交互状态机 | 27 个测试 |
| `DshSession` | L2 会话窗口：seq 排序、surface/transcript 分离、压缩流展开、三代格式解码 | 50 个测试 |
| `DshPresenter` | L3 装配：事件 → `ChatNode`，含端到端装配与真实会话回放 | 164 个测试 |
| `App/` | 渲染层与外壳（不在 SwiftPM 包内，只在 iOS 上编译） | 已真机验收，无自动化测试 |

共 **241 个测试**。

**拿 IPA**：每次推到 main，`Build IPA` workflow 产出 `dsh-swift-<short-sha>-unsigned.ipa`
（Actions 页面该次运行的 Artifacts，artifact 名 `dsh-swift-ipa`，保留 14 天；
或 `gh run download <run-id> -n dsh-swift-ipa`）。包已做 ad-hoc 签名，面向装了
AppSync 一类机制的越狱设备。

**当前进度、已知缺口和卡点**在 [`docs/PROGRESS.md`](docs/PROGRESS.md)。

---

## 一条架构边界：核心三层不碰 UIKit

本机装了 Swift 6.4.1 的 Windows 工具链，所以 `swift test` 在开发机上直接能跑：

```
$ swift test
Executed 241 tests, with 0 failures
```

协议层、窗口层、装配器都是纯逻辑，没有理由依赖 UIKit。守住这条边界，迭代就不必
每次等 macOS runner 排队；破掉它，开发速度立刻掉一档。CI 的 `test-linux` job 就是
这条边界的守卫。

渲染层放在 `App/`，作为独立的 Xcode target 存在，依赖这三个模块，但不反向污染它们。

---

## 线协议常量的漂移闸门

`Sources/DshProtocol/WireConstants.swift` 是 host 侧常量的镜像。这些值的特点是
**改一个字符不会编译失败，只会在运行时静默失效**——流不来、事件不到、审批答不上，
而且没有任何错误信息。

所以有 `Tools/check-wire-drift.mjs`，把镜像和实际安装的 host 包对拍：

```
$ node Tools/check-wire-drift.mjs
host 版本: 0.2.1-rc.5

## 常量
  ok eventsEndpoint = "$events"
  ok eventsResultEndpoint = "$events/result"
  ok muxPath = "/api/remote.mux"
  ok cookieNamePrefix = "dsh-auth-"

## 事件 allowlist
  host 28 条 / swift 28 条
  waterfall: approval/request, user-questions/request

一致（host 0.2.1-rc.5）
```

它第一次运行就抓到了一处真漂移：设计文档按 `0.1.7-rc.1` 的源码树写的是 **23 条**
转发事件，实际安装的 `0.2.1-rc.5` 是 **28 条**（多了账号过期、凭据记录、插件市场、
定时任务相关的 5 条）。这就是这个工具存在的理由。

---

## 配对：走 `/connect`，不是 `GET /?token=`

host 有两条换发凭证的路，长得很像，但给的东西不一样：

| | `GET /?token=` | `GET /connect?token=` |
|---|---|---|
| 给谁用 | 浏览器 | **原生客户端** |
| cookie 版本 | v1 | v2（payload 多一个 `id`） |
| Peer | 所有浏览器连接共享一个 | 每次换发一个独立的 |
| 能否声明 `interactions` | 不能 | **能**（`answer` / `none`） |
| 一个凭证挂第二条 socket | 允许 | 回 **409** |

走错的后果是最难查的那一类：App 能连上、`$events` 流照样 ready、**但审批永远答不上，
而且不报错**。因为"能不能答 waterfall"不是流的属性，而是换发凭证时就固定下来的
（host 侧 `client.answers = peer.principal.kind === 'owner'`）。

还有两条实测出来的坑：

- **`interactions` 的 host 默认值是 `none`**，不显式传就是只读客户端。本仓库默认传 `answer`。
- **凭证的生命周期绑在 mux socket 上**。socket 断开 → Peer dispose → 凭证彻底失效，
  必须重走 `/connect`。所以重连要分两级：先试重开 mux，收 401 就回去重新换发。

错误分三类提示，混在一起用户无法自救：

- **403** = host 的 `trustedHosts` 没收录你用的那个地址（**和 token 对不对无关**）；
- **401** = token 不对，或 host 换过签名密钥；
- **409** = 这份凭证已在别处连着，换一份新的。

---

## 审批：谁先点谁生效

一个 `approval/request` 会**同时投递给所有** `interactions=answer` 的客户端——电脑上的
浏览器和手机 App 都算。任一端回 `result` 或 `rejected` 就立即结算，其余端收到
`{type:'cancel', eventId}`。

`cancel` 帧**本身区分不了原因**，所以客户端要靠本地状态区分三种终态：

- 自己点的 → 卡片消失，正文出现对应节点；
- 别人先点了 → 卡片转灰 +「已在其他设备处理」；
- 上游取消或断代 → 卡片转灰 +「已失效，请重新发起」。

回 `next` 只是"我不管"，只有当**所有**客户端都回 next 才真按 next 放行。

---

## UI 的设计依据是数据，不是猜测

节点模型（`Sources/DshPresenter/ChatNode.swift`）的形状来自对 **326 个真实会话 /
523,473 条事件**的全量统计。三个数字决定了设计重点：

| 发现 | 数字 | 后果 |
|---|---|---|
| 正文的 94.3% 是 reasoning，不是回答 | reasoning 57.2 MB vs 正文 3.5 MB | 思考块是第一等公民，默认收起成一行摘要 |
| `reasoning-chunks` 占全部事件的 44.3% | 231,948 / 523,473 | 它是流式渲染的性能主路径 |
| 前 5 个工具占全部调用的 88.1% | pwsh 53.9% + read/edit/write/grep | 专用卡只做 5 个，长尾 55 种走通用卡 |

还有一条：`user/message` 里**只有 28.9% 是真人写的**。必须白名单渲染
（只认 `source.kind ∈ {user, user-question-reply}`），否则本样本里会多出 2,466 条
假的用户气泡。

---

## 真机验收

2026-11-01，iPhone 13 / iOS 15.3.1（越狱，AppSync 安装）。首页显示四个库的常量
（转发事件 28 / 需答复 2 / surface 类型 5 / 已建模事件 41），进入样例会话后节点全部
渲染正确、展开与滚动正常。**这次验收的是渲染层，不是端到端连 host。**
细节与缺口见 [`docs/PROGRESS.md`](docs/PROGRESS.md)。

---

## 开发计划

远程档先行，iSH 内核在后。

| 阶段 | 内容 | 状态 |
|---|---|---|
| **P0** | 配对：`/connect` 换发、403/401/409 分治、Keychain、两级重连 | 协议逻辑完成，传输/存储/UI 未接 |
| **P1a** | mux 流、`session.follow`、dense index、rebaseline | 解码与压缩流展开完成，流未接 |
| **P1b** | 装配器 | ✅ 完成 |
| **P1c** | `$events` 与待决交互 | 状态机完成，订阅未接 |
| **P1d** | 壳层：侧栏、会话列表、设置 | 未开始 |
| **P1e** | 渲染层 | ✅ 第一版完成并真机验收 |
| **P2** | iSH 内核：node flags、三道硬门、AOT | 未开始，范围已重估 |

鉴权按"够用就行"处理：局域网手填/扫码 token。跨网络访问交给 Tailscale 或使用者
自己的反向代理（配合 WebAuthn 一类的网关），**App 侧不自己做 NAT 打洞或中继** ——
那是另一个项目，而且已有成熟方案。

---

## 许可

GPL-3.0（与上游 OpenMinis 一致）。
