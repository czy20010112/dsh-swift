import Foundation

/// 一条等待客户端答复的请求。
///
/// 只有两个事件会走到这里（host 转发表里 28 条中仅这 2 条是 `waterfall`）：
/// `approval/request` 与 `user-questions/request`。它们就是"App 能不能干活"的
/// 全部入口——其余 26 条都是单向通知。
public struct PendingInteraction: Sendable, Equatable, Identifiable {

    public enum Kind: Sendable, Equatable {
        /// 要不要让它执行这个动作。
        case approval(command: String?)
        /// 它在问你一个问题。
        case question(prompt: String?, options: [String])
    }

    /// host 给的 eventId，答复时要原样带回。
    public var id: String
    /// 发起这条请求的 agent。子代理也会发审批。
    public var agentId: String
    public var kind: Kind
    public var receivedAt: Date

    public init(id: String, agentId: String, kind: Kind, receivedAt: Date) {
        self.id = id
        self.agentId = agentId
        self.kind = kind
        self.receivedAt = receivedAt
    }
}

/// 一条待决交互的最终去向。
///
/// 三种终态在 UI 上必须给不同文案，否则用户不知道发生了什么——
/// 而 host 发来的 `cancel` 帧**自身区分不了**后两种，得靠客户端本地状态判断。
public enum InteractionOutcome: Sendable, Equatable {
    /// 本机答复了。
    case answered(WireConstants.OutcomeKind)
    /// 别的客户端先答了（电脑上的浏览器通常也连着同一个 host）。
    case answeredElsewhere
    /// 上游撤回，或连接断代导致作废。
    case abandoned
}

/// 待决交互的槽位。
///
/// 为什么需要一个显式的状态机：审批这条路径上有三个并发来源——用户点按钮、
/// host 发 cancel 帧、连接断代——它们可以任意交错。没有状态机就会出现
/// "点了允许但卡片还在"或者"卡片消失了但答复没发出去"。
///
/// 同一时刻只允许一个 pending。host 侧可以同时有多条，但手机屏幕上并排两张
/// 审批卡是没法用的，所以多出来的排队。
public struct InteractionSlot: Sendable {

    /// 当前正在等用户处理的那条。
    public private(set) var current: PendingInteraction?
    /// 排队中的。
    public private(set) var queue: [PendingInteraction] = []
    /// 已经答复过、但还没收到 host 确认的 eventId。
    ///
    /// 用它区分"我答的"和"别人答的"：答复发出后 host 会回一个 cancel 帧，
    /// 如果这个 id 在集合里，说明是自己答复的回响，不是被别人抢了。
    private var answeredIds: Set<String> = []

    /// 本代连接的 clientId。`$events` 的 ready 帧给的。
    ///
    /// 重连后是新的一代，旧 clientId 作废，所有 pending 都要标 abandoned——
    /// 不能默默丢掉，用户正等着那个审批。
    public private(set) var clientId: String?

    public init() {}

    /// `$events` 流 ready。开始新的一代。
    ///
    /// - Returns: 因为换代而作废的交互。UI 要把它们标成"已失效"。
    public mutating func beginGeneration(clientId: String) -> [PendingInteraction] {
        let orphaned = ([current].compactMap { $0 }) + queue
        self.clientId = clientId
        current = nil
        queue = []
        answeredIds = []
        return orphaned
    }

    /// 连接断了，这一代结束。
    ///
    /// - Returns: 作废的交互。
    public mutating func endGeneration() -> [PendingInteraction] {
        let orphaned = ([current].compactMap { $0 }) + queue
        clientId = nil
        current = nil
        queue = []
        answeredIds = []
        return orphaned
    }

    /// 收到一条 waterfall 请求。
    ///
    /// ready 之前收到的一律丢弃：没有 clientId 就没法答复，留着只会让 UI 显示
    /// 一张点了没反应的卡片。
    public mutating func receive(_ interaction: PendingInteraction) -> Bool {
        guard clientId != nil else { return false }
        if current == nil {
            current = interaction
        } else if current?.id != interaction.id,
                  !queue.contains(where: { $0.id == interaction.id }) {
            queue.append(interaction)
        }
        return true
    }

    /// 用户答复了当前这条。
    ///
    /// 调用方负责把答复真的发给 host（`POST /api/$events/result`）。这里只管状态。
    ///
    /// - Returns: 要发给 host 的答复载荷，`nil` 表示当前没有待决项。
    public mutating func answer(
        _ outcome: WireConstants.OutcomeKind
    ) -> (clientId: String, eventId: String, outcome: WireConstants.OutcomeKind)? {
        guard let clientId, let interaction = current else { return nil }
        answeredIds.insert(interaction.id)
        advance()
        return (clientId, interaction.id, outcome)
    }

    /// 收到 host 的 `cancel` 帧。
    ///
    /// 这个帧有三种可能的来源，而帧里**没有**区分它们的字段：
    /// 1. 自己刚答复的回响 → 正常，不用提示；
    /// 2. 别的客户端先答了 → 要告诉用户"已在其他设备处理"；
    /// 3. 上游取消（agent 自己放弃了，或 Context 释放） → "已失效"。
    ///
    /// 靠 `answeredIds` 区分第 1 种，剩下两种在客户端侧无法区分，
    /// 一律按"别处处理"报告——这是更常见的情况，而且文案对两者都成立。
    public mutating func cancel(eventId: String) -> InteractionOutcome? {
        if answeredIds.remove(eventId) != nil {
            return nil  // 自己答复的回响
        }
        if current?.id == eventId {
            advance()
            return .answeredElsewhere
        }
        if let index = queue.firstIndex(where: { $0.id == eventId }) {
            queue.remove(at: index)
            return .answeredElsewhere
        }
        return nil  // 不认识这个 id，忽略
    }

    private mutating func advance() {
        current = queue.isEmpty ? nil : queue.removeFirst()
    }

    /// 能不能答复。ready 之前不行。
    public var canAnswer: Bool { clientId != nil && current != nil }
}
