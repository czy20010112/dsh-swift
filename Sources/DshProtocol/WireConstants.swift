/// DSH host 线协议常量的 Swift 镜像。
///
/// 这些值在 host 侧是硬编码常量，客户端必须逐字匹配。它们是**整个客户端最脆弱的
/// 一层**：改一个字符不会编译失败，只会在运行时静默失效（流不来、事件不到、
/// 审批答不上）。所以：
///
/// 1. 每个常量都标注了核对来源与版本；
/// 2. `Tools/check-wire-drift.mjs` 在 CI 里把这些值与实际安装的 host 包对拍，
///    漂移即红。不要手工"顺便改一下"。
///
/// 核对基准：`@deepseek-ai/dsh@0.2.1-rc.5`（2026-11-01 实测）。
public enum WireConstants {

    // MARK: - 路径

    /// 唯一的多路复用流端点。所有流（session.follow / $events / terminal 等）都挤在这一条
    /// WebSocket 上，靠 `streamId` 区分。
    ///
    /// 来源：`dsh-api-gateway` `REMOTE_STREAM_MUX_PATH`。
    public static let muxPath = "/api/remote.mux"

    /// 一元 RPC 的路径前缀，完整形式是 `/api/<namespace>/<method>`。
    public static let rpcPathPrefix = "/api/"

    /// 转发事件流的 endpoint 名。它不是 HTTP 路径，而是 mux `open` 帧里的 `endpoint` 值。
    ///
    /// 来源：`REMOTE_EVENT_STREAM_ENDPOINT`。
    public static let eventsEndpoint = "$events"

    /// 答复 waterfall 的一元 RPC 端点（走 `POST /api/$events/result`）。
    ///
    /// 来源：`REMOTE_EVENT_RESULT_ENDPOINT`。
    public static let eventsResultEndpoint = "$events/result"

    /// 原生客户端换发凭证的端点。**不是** `GET /?token=`（那条是浏览器档，发 v1 cookie
    /// 且所有连接共享一个 Peer）。
    ///
    /// 这条端点发 v2 cookie、每次换发创建独立 Peer，并接受 `interactions` 声明。
    /// 走错端点的后果：App 变成只读客户端，且 `$events` 流照样 ready、不报错。
    public static let connectPath = "/connect"

    /// 浏览器档的换发路径，仅在回退时使用。
    public static let indexPath = "/"

    // MARK: - 鉴权

    /// 会话 cookie 名的前缀，完整形式是 `dsh-auth-<base64url(sha256(authority))>`。
    ///
    /// `authority` 是 `host:port`（**含端口**），所以换端口 = 换 cookie 名。
    /// 推论：embedded 档必须用固定端口，否则每次冷启都要重新换发。
    public static let cookieNamePrefix = "dsh-auth-"

    /// 换发凭证时在 query 里携带 launch token 的参数名。
    public static let tokenQueryKey = "token"

    /// 声明本客户端是否参与 waterfall 答复的参数名。
    public static let interactionsQueryKey = "interactions"

    // MARK: - 帧类型

    /// 客户端 → host 的 mux 帧类型。
    ///
    /// host 用 `exactKeys` 做**严格**校验：多一个字段、少一个字段都会被拒。
    /// 所以 Swift 侧序列化时**不能输出值为 null 的可选字段**。
    public enum ClientFrameType: String, Sendable {
        /// 开流。必带 `streamId` / `endpoint` / `payload`，三者缺一不可。
        case open
        /// 上行数据（如审批答复走的不是这条，而是独立的 HTTP RPC）。
        case item
        /// 半关闭：不再上行，但继续收下行。
        case end
        /// 取消整条流。
        case cancel
    }

    /// host → 客户端的 mux 帧类型。
    public enum HostFrameType: String, Sendable {
        case item
        case error
        case end
    }

    /// `$events` 流下行的帧类型。
    public enum EventFrameType: String, Sendable {
        /// 每代 generation 的第一帧，携带 `clientId` 与 host facts。
        /// 必须先读到它才能发任何答复。
        case ready
        /// 单向通知，不需要答复。
        case emit
        /// 需要客户端答复的请求（审批 / 提问）。
        case waterfall
        /// 撤回一条 pending。**注意**：帧本身不区分原因——可能是别的客户端先答了，
        /// 也可能是上游取消。要靠本地"我有没有答过"来区分。
        case cancel
    }

    // MARK: - 答复结果

    /// waterfall 答复的三种结果。
    public enum OutcomeKind: String, Sendable {
        /// "我不管"，交给其他客户端或默认策略。只有当**所有**客户端都回 next
        /// 才真的按 next 放行。
        case next
        /// 给出结果，立即结算；其余客户端会收到 cancel。
        case result
        /// 拒绝，立即结算。
        case rejected
    }

    // MARK: - 交互姿态

    /// 换发凭证时声明的交互能力。
    public enum Interactions: String, Sendable {
        /// 参与 waterfall 答复（能批准审批、回答提问）。
        case answer
        /// 只读。**host 侧的默认值**——不显式声明就是这个。
        case none
    }

    // MARK: - 事件 allowlist

    /// host 转发的事件全集（**28 条**，实测于 0.2.1-rc.5）。
    /// 不在这张表里的事件根本不会过线。
    ///
    /// 来源：`@deepseek-ai/dsh-api-remotes` 的 `API_REMOTE_FORWARDED_EVENTS`。
    ///
    /// 注意：设计文档写的是 23 条，那是按 `dsh-checkout@0.1.7-rc.1` 的源码树数的。
    /// 实际安装的 0.2.1-rc.5 多了 5 条（账号过期、凭据记录、插件市场、定时任务）——
    /// 这正是 `Tools/check-wire-drift.mjs` 第一次运行就抓到的漂移。
    public static let forwardedEvents: [String: EventMode] = [
        "agent-preset/selected": .emit,
        "api-session/activity": .emit,
        "api-session/added": .emit,
        "api-session/error": .emit,
        "api-session/removed": .emit,
        "api-session/status": .emit,
        "approval/request": .waterfall,
        "commands/change": .emit,
        "cordis/dynamic-package": .emit,
        "cordis/dynamic-retract": .emit,
        "cordis/inspect-query": .emit,
        "cordis/inspect-query-resolved": .emit,
        "cordis/request-run": .emit,
        "cordis/request-run-resolved": .emit,
        "credentials/record-updated": .emit,
        "credentials/reference-updated": .emit,
        "deepseek-account/model-sign-in-required": .emit,
        "deepseek-account/session-expired": .emit,
        "goal/activation-changed": .emit,
        "llm/adapters-updated": .emit,
        "permission-presets/catalog-changed": .emit,
        "plugin-manager/changed": .emit,
        "plugin-manager/install-log": .emit,
        "plugin-manager/install-state": .emit,
        "plugin-market/changed": .emit,
        "schedule/changed": .emit,
        "settings/document-updated": .emit,
        "user-questions/request": .waterfall,
    ]

    /// 转发模式。只有 `waterfall` 需要客户端答复。
    public enum EventMode: String, Sendable {
        case emit
        case waterfall
    }

    /// 需要客户端答复的两个事件。这两条就是"App 能不能干活"的全部入口。
    public static let waterfallEvents: Set<String> = [
        "approval/request",
        "user-questions/request",
    ]
}
