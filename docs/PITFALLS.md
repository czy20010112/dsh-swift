# 踩过的坑

> 收录标准：**出错时不报错**的那些。会编译失败或崩溃的问题自己会暴露，不值得写；
> 这里记的是"看起来能跑、用久了才发现"的。每条给出判据和对应的测试。

---

## 协议

### 1. 走 `GET /?token=` 会得到一个只读客户端，而且不报错

host 有两条换发凭证的路：

| | `GET /?token=` | `GET /connect?token=` |
|---|---|---|
| 给谁 | 浏览器 | **原生客户端** |
| cookie | v1 | v2（payload 多 `id`） |
| Peer | 所有浏览器共享一个 | 每次换发独立一个 |
| `interactions` | 不支持 | `answer` / `none` |
| 同一凭证第二条 socket | 允许 | **409** |

**症状**：App 能连上、`$events` 流照样 ready、正文照样流——但审批永远答不上，
且没有任何错误。

**根因**：能不能答 waterfall 是**换发凭证时**就固定的，不是流的属性
（host 侧 `client.answers = peer.principal.kind === 'owner'`）。

**另外**：`interactions` 的 host 默认值是 `none`，不显式传就是只读。

**判据**：换发后检查 cookie 值是否以 `v2.` 开头。

### 2. 凭证的寿命绑在 mux socket 上，不是 cookie 的 30 天

socket 断开 → Peer dispose → 该凭证彻底失效，必须重走 `/connect`。

**症状**：重连后一直 401，但 cookie 明明还没过期。

**处置**：重连分两级——先试重开 mux，收 401 就回去重新换发。token 要持久保存。

测试：`InteractionSlotTests.testAnswerAfterGenerationEndFails`

### 3. `cancel` 帧有三种原因，帧里没有字段区分

host 在这三种情况下都发同一个 `{type:'cancel', eventId}`：

1. 你自己刚答复的回响；
2. 别的客户端先答了；
3. 上游撤回（agent 放弃，或 Context 释放）。

**症状**：把全部 cancel 都当"失效"提示，用户每次自己点完都看到一句"已失效"。

**处置**：本地记已答复的 eventId 来识别第 1 种。2 和 3 在客户端侧无法区分，
一律按"已在其他设备处理"报告——更常见，而且文案对两者都成立。

测试：`InteractionSlotTests.testCancelAfterOwnAnswerIsSilent` 等 4 个

### 4. 403 和 401 必须分开提示

- **403** = host 的 `trustedHosts` 没收录你用的那个地址。**和 token 对不对无关**。
- **401** = token 不对，或 host 换过签名密钥。

**症状**：403 时提示"请重新扫码"，用户扫一百次也没用——要改的是 host 配置。

### 5. mux 帧用 `exactKeys` 严格校验

多一个字段、少一个字段都被拒。所以 Swift 侧序列化**不能输出值为 null 的可选字段**。

`$events` 的 open 帧还要求 `payload.args` 是**空对象**（host 侧显式检查
`ownKeys(payload.args).length !== 0` 就报错）。

### 6. cookie 名绑定 `host:port`，含端口

cookie 名 = `dsh-auth-` + base64url(sha256(authority))，authority 含端口。

**推论**：设备内嵌档必须用**固定端口**。用 `--port 0` 的话每次冷启 authority 都变，
旧 cookie 永远命中不了。

测试：`CookieNameTests.testPortChangesCookieName`

### 7. host 实际转发 28 个事件，不是文档说的 23 个

设计文档按 `0.1.7-rc.1` 的源码树数的是 23 条；实际安装的 `0.2.1-rc.5` 是 28 条
（多了 `deepseek-account/session-expired`、`deepseek-account/model-sign-in-required`、
`credentials/record-updated`、`plugin-market/changed`、`schedule/changed`）。

**这就是 `Tools/check-wire-drift.mjs` 存在的理由**——它第一次运行就抓到了这个。
waterfall 仍然只有 2 条。

---

## 会话数据

### 8. seq 必须是 Double

实时增量是"合成事件"，带**小数 seq**（host 算法 `durableCursor + 1 - 1/(n+1)`），
靠小数插在已落盘事件之间。

**症状**：用 Int 排序，所有实时内容塌到同一个位置。

测试：`SessionWindowTests.testLiveChunksSortBetweenDurableEvents`

### 9. `surfaceOp.replace` 遮蔽的是模型上下文，不是对话记录

**这一条最初写反了，按错的版本实现过。**

最初的理解：replace 是"摘掉 `[startSeq, endSeq]` 的旧记录、再插入新记录"，
并为"先删后插"的顺序写了 3 个测试。

回放真实会话推翻了它：`compact-checkpoint` 的替换区间最宽跨 **1,298 个 seq**，
照"先删后插"执行，压缩一次就把用户看过的整段历史从界面上抹掉。

正确语义来自 host 的 web 客户端（`dsh-client-ui-chat`，`isAppendSurfaceEvent` 的注释）：
会话日志有两条平行视图——**surface**（模型上下文，replace 会遮蔽旧内容）和
**transcript**（人看的对话记录，只由 append 事件构成，被遮蔽的内容照常显示）。
replace 出来的副本"只给模型看"。

**现在的实现**：`SessionWindow` 不删任何记录，`shadowed(startSeq:endSeq:)` 只回答
"哪些被遮蔽了"。`SurfaceRole` 把每条事件分成 transcript / modelOnly /
compactionCheckpoint / notSurface，只有前者和最后者进正文。

实测 replace 的来源（全库）：`tool/result` 91、`user/message`(compact-checkpoint) 35、
`system/message` 22、`user/message`(plugin) 6。只有这五种 surface 事件带 `surfaceOp`，
而且是 100% 都带。

**教训**：设计文档给的语义没核对 host 源码就写成了测试。测试全绿，但它锁定的是错的行为。

测试：`SurfaceRoleTests`（13 个）、`ReplayTests.testReplaceNeverRemovesTranscriptEvents`
（在真实夹具上验证正文事件集合不被 replace 改动）

### 10. 压缩流的 `dt` 比 `texts` 少一个元素

第一个分片的时间**就是** `time0`，之后每个分片累加一个 dt。

**症状**：想反了（以为 dt[0] 对应第一个分片）会让整条 run 的时间戳全部偏移一格。
不报错，只是"思考了多久"算错。

实测样本：texts=7 / dt=6、texts=11 / dt=10、texts=10 / dt=9。

测试：`AssistantStreamTests.testFirstChunkKeepsTime0`、`testTimesAccumulateDeltas`

### 11. 跨 run 的空档也是思考时间

每条 run 的 `dt` 只覆盖它内部的分片间隔；run A 的最后一片到 run B 的第一片之间
还有一段真实等待。

**症状**：只累加各 run 自己的 dt 会严重低估。实测夹具里 5 ms 的内部时间
实际跨越了 68 ms。

测试：`ReasoningAssemblerTests.testDurationIncludesGapsBetweenRuns`

### 12. `chunk.index` 是内容块身份，不是分片序号

同一段文字的每个 delta 都重复同一个 `index`。

**症状**：把它当分片序号，一段回复会塌成"一字一行"。

### 13. 两代会话格式的流分片位置不同

- 旧代（实测 56 个会话，无 `version` 字段）：`reasoning-chunks` / `text-chunks` /
  `tool-call-chunks` 是**顶层行**，带 `seq0` + `time0`；
- v4（257 个，`version:4`）：同样结构**嵌在** `assistant/message` 的
  `data.stream` 数组里，只带 `time0`。

两代都要能读——用户的旧会话要能打开。

### 14. `.jsonl.zstd` 是多帧追加写

一个文件里多个 zstd frame 连在一起，必须按 magic `28 B5 2F FD` 切帧后逐帧解压再拼接。
一把梭解压只能拿到第一帧。

### 15. `user/message` 里只有 28.9% 是真人写的

实测 20 种 `source.kind`，只有 `user`(1,005) 和 `user-question-reply`(3) 是人写的。
其余 18 种是注入：`skill-catalog`(372)、`subagent-settled`(358)、`tool-jobs`(331)、
`team-message`(329)、`agent-instructions`(309)、`runtime-context`(305)……

**必须白名单渲染**。做成黑名单的话，这批样本会刷出 2,466 条假的用户气泡。

### 16. `tool/result` 的文本在 `data.message.content[].text`

不在 `data.content`。我第一版扫描脚本就是找错了字段，量出来"所有结果都是 2 字符"——
那其实是 `[]` 的 JSON 字符串长度。

配对靠 `data.message.toolCallId` 对应 `tool/call` 的 `data.callId`，**不能靠顺序**，
工具可以并发。

---

## 工程

### 17. git 不跟踪空目录，CI 会因此红

`Tests/DshPresenterTests/` 建了但还没写测试文件，本机 `swift test` 能过（目录在），
推上去 Linux job 报 `Source files for target DshPresenterTests should be located under...`。

**判据**：`git ls-files Tests/` 看目录是否真的进了仓库。

### 18. node 的 V8 flag 注入有**四处**，不是一处

`deps/ish/kernel/exec.c` 那处最有名，但宿主侧还有两处会在不同路径上生效：

| 位置 | 何时生效 |
|---|---|
| `deps/ish/kernel/exec.c:925,927` | guest 内 `execve` 名为 `node` 的程序（sh / npx / shebang 拉起的） |
| `src/ios/iSH/ISHKernel.m:1025-1028` | 宿主直接 `do_execve`，**不经过** `sys_execve` |
| `src/ios/iSH/ISHShellExecutor.m:475-478` | 同上，ShellExecutor 路径 |
| `deps/ish/xX_main_Xx.h:146-149` | 只用于 Mac/Linux CLI，App 不走 |

**症状**：只改 `exec.c` 那处，宿主直接起的 node 照旧是 512MB + jitless，
而且看起来像"改了没生效"。

### 19. 只删 `--jitless` 会把 Sparkplug / Maglev / TurboFan 全打开

上游（aot 分支）的"默认模式"确实去掉了 `--jitless`，但**同时加了**
`--no-sparkplug --no-maglev --no-opt --regexp-interpret-all` —— JS 仍然全在解释器里跑。

**症状**：照搬"去掉 jitless"这半句，等于回到当初加它要规避的问题
（`exec.c:910` 的注释：V8 的代码生成与 iSH 的 JIT 不兼容）。

另外宿主两处还传了 `--no-expose-wasm`。不一起删的话没有 WebAssembly，
Node 自带的 undici 在加载时调 `WebAssembly.compile()` 会炸。

而且上游新逻辑把"调用方自己传了 `--jitless` 或 `--no-expose-wasm`"当作**强制回退**
到 jitless 的信号。所以即便把 submodule 升级到 aot 分支，宿主那两处不改，
node 照样是 jitless。

### 20. 把堆从 512MB 放到 1GB 会把 OOM 变成整 App 被杀

代码里没有任何逻辑由 512 推导出来，所以改常量本身是安全的。危险在别处：
当前 pin 的 commit 里内核的匿名页上限几乎不起作用（`kernel/mm.h:13` 写
`1048576` 页，注释却说是 2GB —— 因为计数按 4KB guest 页算而宿主页是 16KB，
实际放行约 16GB）。上游收紧这个上限的三个提交都不在我们 pin 的版本里。

**后果**：堆长过 512MB 时，现在是 V8 自己 fatal OOM（能看到堆栈）；
放到 1GB 后更可能是整个 App 被 jetsam SIGKILL，**会话状态一起丢**。

上游正是**以 512 为前提**把匿名页上限压回 2GB 的。

### 21. "去掉 jitless 快 3.6 倍"这个数字不能套用

上游自己的实测是默认模式 vs jitless：15.6s → 14.0s，约 **10%**，
而且那是有 AOT 映像、在 Mac CLI 上、9 个 agent 的负载。

真正的大头是 **AOT 映像**：App 内开关 AOT 的差距是 1.4x（node 启动）到 3.9x（`grep -r`）。
V8 运行时生成的代码不被映像覆盖，仍走 gadgets 解释执行。

代价：node 单模块的 `.S` 有 605MB、iOS objects 合计 306MB，录一次约 10 分钟；
而且 ABI 一变就要全部重录。

### 22. 本地 iSH submodule 落后上游 62 个提交

pin 在 `3f6384c7`（2026-08-23 / v2.0.0-95），origin/master 已到
`e6521d9c`（2026-09-29 / v2.0.0-157）。

配置化路径（`ISH_NODE_MODE=jitless` 环境变量）**只在 `origin/feat/aot-family-match`
分支上**，没进 master，也没进我们 pin 的版本。两组 flag 里的 512 都还是硬编码。

**判据**：`cd deps/ish && git log --oneline -1 && git describe --tags`

## 回放真实会话发现的（15 个夹具 / 覆盖全部 53 种事件）

### 24. 会话格式有三代，不是两代

本机 357 个文件：v0 58 个、v3 31 个、v4 268 个。旧代 header 带 `version: 0`，
并非没有 version 字段。v3 的流分片像 v4 一样嵌在 `data.stream` 里，但
tool/result 的结构像 v0。

另有 9 个会话目录同时放着多代文件（id 相同），v4 文件的 seq 从 0 重新开始，
是迁移留下的副本。读会话时要挑最新一代，不能两份都读。

### 25. 只有 v4 有 `message.toolCallId`

v0 和 v3 只能从 `message.source.callId` 取配对 id，文本还多套一层 `tool-result` 块。
只认 `toolCallId` 的话，v0 和 v3 的 tool/result **全部**配不上，工具卡永远显示"运行中"。

### 26. v0 的 `surfaceOp.replace` 用 `start`/`end`

v3 和 v4 用 `startSeq`/`endSeq`。另外 `surfaceOp: "append"` 是字符串值，
全库约 9.6 万次，是最常见的形式。解码时两种都要认。

### 27. 有一类 replace 会删掉一大段各种类型的事件

来源是 `user/message`：v4 里 `source.kind=compact-checkpoint` 的有 35 次，
v0/v3 里 `plugin` 的有 19 次。区间最大跨 **1,298 个 seq**，里面混着 tool/call、
assistant/message 等各种事件。

`SessionWindow.replace` 照字面执行会把整段历史删掉。**已解决**：replace 不再删除对话
记录（见第 9 条），检查点识别为 `SurfaceRole.compactionCheckpoint`，带 `compactionId`。

其余 replace 都是单个 seq 的同类型替换。一个 call 对应多个 result 时，
第二个 result 一定带 replace（v0 5 次、v3 26 次、v4 84 次）。

### 28. v3 会话丢过事件

31 个 v3 文件里 13 个有 seq 断档，共缺 852 个 seq，都不在 compaction 的
shadowedSeqs 里。12 个文件出现孤儿 tool/result（共 33 个），它们的
`sourceEventSeqs` 正好指向断档。另有 39 个 tool/call 没有结果。v0 和 v4 没有这个问题。

客户端必须容忍配不上的 call 和 result，不能假设一一对应。

### 29. v0 的一条 run 占 n 个 seq

它占用 `seq0 ..< seq0+n`，下一条事件的 seq 正好是 `seq0+n`，9,061 处无一例外。
所以 v0 run 之后的 durable cursor 应取 `seq0+n-1`。`retireLiveChunks(upTo:)`
只清 `(N-1, N)` 区间，遇到 v3 的断档会让 live 分片滞留（`v3-02` 滞留了 6 条）。
这是窗口的问题还是协议约定，**待读 host 源码确认**。

### 30. v4 里有负的 dt

9 个，最小 -1462 ms，其中 7 个在 tool-call 分片里。`AssistantStream.duration`
会把它们减掉，耗时偏小。**已解决**：负 dt 钳到 0（`AssistantStream.clampedDelta`），
耗时不再偏小，展开后的时间戳单调。

### 31. 落盘数据里没有小数 seq

小数 seq 只出现在实时连接里。回放测试里的 live 分片是按
`cursor + 1 - 1/(n+1)` 现场合成的，不是从夹具读的。

### 32. 夹具脱敏要在拼接后的文本上做

流式分片会把一个 IP 或路径切成两半，逐片匹配认不出来。第一次推送的夹具因此
漏了一个公网 IP（8 处）和若干 `/mnt/d/...` 路径。现在 `Tools/export-fixtures.mjs`
先拼接整条 run 再匹配，替换后再拆回原分片，分片数和 dt 关系保持不变。

另一个教训：脱敏脚本本身在公开仓库里，**不能把"要过滤的私人标识"写成字面值**。
现在它们从环境变量 `DSH_FIXTURE_PRIVATE_DOMAINS` / `DSH_FIXTURE_PRIVATE_TERMS` 读。

### 33. `llm/retry-started` 是 `llm/retry` 的回声，不能出节点

两者总是成对出现（实测 260 对 259），顺序是 `assistant/attempt → llm/retry →
llm/retry-started → assistant/attempt → …`。

**症状**：把 retry-started 也当节点，它会插在两次 retry 之间，"连续重试只留最新一条"
的合并就失效。一份夹具里 1/5 到 5/5 的重试在正文里摆成了 10 行。

### 34. 压缩生命周期的四个事件各出节点会留下一串噪音

`compaction/start`、`summary`、`prune`、`end` 各出一行，一次压缩就在正文里
留下四五行。压缩对用户只有一个意义："从这里往前的细节模型看不到了"，
所以只在检查点位置放一个 `.compaction` 标记。

### 23. 不要在公开仓库里放内部文档

评审稿和 UI 设计文档里有内网地址、工时估算、对私有仓库的逆向细节。
这些留在私有工作区，公开仓库的 README 只引结论。

测试用例里也会漏——第一版把开发机的真实内网地址和私人域名写进了 cookie 名的金标，
后来换成 RFC 5737 的文档地址（`192.0.2.10`）和 `dsh.example.com`，金标重算。

**判据**：提交前 grep 一遍内网段、用户名、真实域名。
