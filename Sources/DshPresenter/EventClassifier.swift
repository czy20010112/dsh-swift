import DshSession

/// 决定一个事件有没有 UI 后果。
///
/// **为什么不建一张"事件全集"的表**：事件词表随插件漂移。三份样本分别数出
/// 54 / 47 / 39 种，交集远小于并集。本机样本里就有 `web/deepseek-search-llm-request`
/// 497 次、`team/message/queued` 332 次这类插件专属事件。
///
/// 所以这里的原则是：**只建模有 UI 后果的，其余一律忽略，未知不报错**。
/// 失效方向是安全的——漏显示一种低频事件是可接受的降级，而对未知事件报错
/// 会让整个会话打不开。
public enum EventClassifier {

    /// 一个事件对界面的影响。
    public enum Effect: Sendable, Equatable {
        /// 产生一个正文节点。
        case node
        /// 只更新会话头的状态行（权限预设、沙箱模式之类），不进正文。
        case headerStatus
        /// 只更新会话元信息（标题）。
        case metadata
        /// 流分片。由对应的装配器处理，自己不产生节点。
        case streamChunk
        /// 结构边界。影响节点归属但自己不显示。
        case structure
        /// 没有 UI 后果。**包括所有未知事件。**
        case ignorable
    }

    /// 实测有 UI 后果的事件。频次来自 326 个会话 / 523,473 条事件。
    ///
    /// 不在这张表里的事件走 `.ignorable`，这是**有意的默认值**而不是遗漏。
    static let effects: [String: Effect] = [
        // --- 流分片（由 ReasoningAssembler / AssistantAssembler 消费）---
        "reasoning-chunks": .streamChunk,     // 231,948 — 占全部事件 44.3%
        "tool-call-chunks": .streamChunk,     // 28,043
        "assistant/chunk": .streamChunk,      // 21,978
        "text-chunks": .streamChunk,          // 3,785

        // --- 结构边界 ---
        "turn/start": .structure,             // 1,271
        "turn/end": .structure,               // 1,265
        "step/start": .structure,             // 41,070
        "step/end": .structure,               // 41,064
        "assistant/attempt": .structure,      // 352

        // --- 产生节点 ---
        "tool/result": .node,                 // 48,044
        "tool/call": .node,                   // 47,955
        "assistant/message": .node,           // 40,924
        "agent/inbox/spliced": .node,         // 4,585 — 比真人发言还多
        "user/message": .node,                // 3,474 — 但只有 28.9% 会真的渲染
        // 压缩生命周期由 compact-checkpoint 的 `.compaction` 标记代表（见 SurfaceRole）。
        // start/end/prune/summary 各出一个节点的话，一次压缩会在正文里留下四五行。
        "compaction/start": .structure,       // 319
        "compaction/end": .structure,         // 319
        "system/message": .node,              // 281
        "llm/retry": .node,                   // 260 — 带失败原因，用户要知道为什么卡住
        // retry-started 只是 retry 的回声（总是紧跟在它后面，实测 259 对 260）。
        // 当成节点会插在两次 retry 之间，打断"连续重试只留最新一条"的合并。
        "llm/retry-started": .ignorable,      // 259
        "todo/write": .node,                  // 231
        "deliverables/presented": .node,      // 131
        "compaction/prune": .structure,       // 89
        "compaction/summary": .structure,     // 41
        "command/run": .node,                 // 42 — 斜杠命令
        "command/done": .node,                // 42
        "goal/change": .node,                 // 26
        "developer/message": .node,           // 20
        "plan/mode": .node,                   // 8

        // --- 会话头状态行 ---
        "permission/preset": .headerStatus,   // 350
        "approval/policy": .headerStatus,     // 350
        "sandbox/mode": .headerStatus,        // 342
        "model/selection": .headerStatus,     // 140

        // --- 会话元信息 ---
        "session/title": .metadata,           // 354

        // --- 明确忽略（有记录但无 UI 后果）---
        "request/header": .ignorable,         // 644
        "workspace/changes": .ignorable,      // 512 — 文件侧栏用，不进正文
        "request/context": .ignorable,        // 370
        "session": .ignorable,                // 326 — 会话头记录
        "session/end-seed": .ignorable,       // 293
        "subagent/catalog": .ignorable,       // 224
        "subagent/descriptor": .ignorable,    // 220
        "image/offload": .ignorable,          // 33
    ]

    /// 这个事件对界面有什么影响。
    ///
    /// 未知事件返回 `.ignorable` —— 这是设计，不是兜底。
    public static func effect(of eventType: String) -> Effect {
        effects[eventType] ?? .ignorable
    }

    /// 这个事件会产生正文节点吗。
    public static func producesNode(_ eventType: String) -> Bool {
        effect(of: eventType) == .node
    }

    /// 这个事件是流分片吗。
    public static func isStreamChunk(_ eventType: String) -> Bool {
        effect(of: eventType) == .streamChunk
    }

    /// 已建模的事件种类数。用于诊断：和实际样本的种类数对比，
    /// 能看出有多少长尾被忽略了。
    public static var modeledCount: Int { effects.count }
}

/// 一次 LLM 重试。
///
/// 实测 260 次 `llm/retry`，带 `failure.{message,code}`、`retry`/`maxRetries`、`delayMs`。
/// 必须显示：重试期间界面上什么都不动，用户不知道是卡住了还是在等——
/// 而 `TRANSPORT` 这类错误可能要重试好几轮。
public struct RetryNotice: Sendable, Equatable {
    public var seq: EventSeq
    /// 失败代码，如 `TRANSPORT` / `RATE_LIMIT` / `TIMEOUT` / `SERVER` / `EMPTY_RESPONSE`。
    public var code: String?
    public var message: String?
    public var attempt: Int
    public var maxAttempts: Int

    public init(seq: EventSeq, code: String?, message: String?, attempt: Int, maxAttempts: Int) {
        self.seq = seq
        self.code = code
        self.message = message
        self.attempt = attempt
        self.maxAttempts = maxAttempts
    }

    /// 一行摘要。
    public var summary: String {
        let reason = Self.readableCode(code) ?? message ?? "未知原因"
        return "重试 \(attempt)/\(maxAttempts) · \(reason)"
    }

    /// 把失败代码翻成人能读的。实测出现的五种全覆盖。
    static func readableCode(_ code: String?) -> String? {
        switch code {
        case "TRANSPORT": return "连接中断"
        case "RATE_LIMIT": return "触发限流"
        case "TIMEOUT": return "超时"
        case "SERVER": return "服务端错误"
        case "EMPTY_RESPONSE": return "空响应"
        case .some(let other) where !other.isEmpty: return other
        default: return nil
        }
    }
}
