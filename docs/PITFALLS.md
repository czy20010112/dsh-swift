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

### 9. `surfaceOp.replace` 必须先删后插

语义是摘掉 `[startSeq, endSeq]` 闭区间里的旧记录，**再**插入新记录。

**症状**：顺序颠倒的话，新记录被自己的删除区间吃掉（当它的 seq 落在区间内时），
或者旧记录留下来变成重复——界面上是"同一条回复出现两次"或"显示旧版内容"。
不报错。

实测 152 次，是"重写更早消息"路径的唯一机制。

测试：`SessionWindowTests.testReplaceRemovesRangeThenInserts` 等 3 个

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

### 23. 不要在公开仓库里放内部文档

评审稿和 UI 设计文档里有内网地址、工时估算、对私有仓库的逆向细节。
这些留在私有工作区，公开仓库的 README 只引结论。

测试用例里也会漏——第一版把开发机的真实内网地址和私人域名写进了 cookie 名的金标，
后来换成 RFC 5737 的文档地址（`192.0.2.10`）和 `dsh.example.com`，金标重算。

**判据**：提交前 grep 一遍内网段、用户名、真实域名。
