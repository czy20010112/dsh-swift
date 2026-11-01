import DshSession

/// 排队中的输入队列。
///
/// `agent/inbox/spliced` **不是"一条排队消息"**，而是对队列数组的一次 splice 操作：
/// 从 `start` 位置删掉 `removedCount` 条，插入 `inserted` 里的若干条。
///
/// 这解释了为什么它在 326 个会话里出现 **4,585 次**（比真人发言的 1,005 次还多）
/// 却只有两个 target：它是队列的**增删日志**，每次入队、出队、改写都记一条。
///
/// 实测字段分布：`target` / `start` / `inserted` 各 4,585 次（必有），
/// `removedCount` 2,191 次（约 48%，缺失时按 0），`outcome` 93 次（2%）。
/// target 取值只有两种：`next-step` 2,312、`next-turn` 2,273。
///
/// **必须按 splice 重放，不能当成"追加一条"**。否则出队操作被忽略，
/// 队列只增不减，界面上会堆积早已被消费掉的待发消息。
public struct InboxQueue: Sendable {

    /// 队列归属。
    public enum Target: Sendable, Equatable {
        /// 插在当前轮次的下一步之前。agent 还在干活，这条会在它下一步看到。
        case nextStep
        /// 等这一轮结束后作为下一轮的输入。
        case nextTurn
        /// 没见过的目标。保留但不渲染——不猜它该插在哪。
        case unknown(String)

        public init(raw: String) {
            switch raw {
            case "next-step": self = .nextStep
            case "next-turn": self = .nextTurn
            default: self = .unknown(raw)
            }
        }
    }

    /// 队列里的一条待发输入。
    public struct Entry: Sendable, Equatable {
        /// host 给的 id。用它去重——重连后 snapshot 与增量会重叠。
        public var id: String?
        /// 来源。**队列条目也带 `source.kind`**，所以这里同样要过白名单：
        /// 队列里混着 agent 自己注入的东西，不是都该显示给用户。
        public var sourceKind: String?
        public var text: String

        public init(id: String?, sourceKind: String?, text: String) {
            self.id = id
            self.sourceKind = sourceKind
            self.text = text
        }
    }

    /// 两条队列各自的内容。
    public private(set) var nextStep: [Entry] = []
    public private(set) var nextTurn: [Entry] = []

    public init() {}

    /// 重放一次 splice。
    ///
    /// - Parameters:
    ///   - target: 哪条队列。
    ///   - start: 起始下标。
    ///   - removedCount: 删掉几条。实测约半数事件不带这个字段，缺失按 0。
    ///   - inserted: 插入的条目。
    public mutating func splice(
        target: Target,
        start: Int,
        removedCount: Int,
        inserted: [Entry]
    ) {
        switch target {
        case .nextStep:
            nextStep = Self.apply(nextStep, start: start, removedCount: removedCount, inserted: inserted)
        case .nextTurn:
            nextTurn = Self.apply(nextTurn, start: start, removedCount: removedCount, inserted: inserted)
        case .unknown:
            break  // 不知道该插哪，忽略而不是猜
        }
    }

    /// 纯函数版的 splice，便于单测。
    ///
    /// 越界的 start 与 removedCount 要钳住而不是崩：乱序到达或窗口从中间开始时，
    /// 本地队列和 host 的不一致是正常的，崩掉比少显示一条严重得多。
    static func apply(
        _ queue: [Entry],
        start: Int,
        removedCount: Int,
        inserted: [Entry]
    ) -> [Entry] {
        let clampedStart = max(0, min(start, queue.count))
        let clampedRemoved = max(0, min(removedCount, queue.count - clampedStart))
        var result = queue
        result.removeSubrange(clampedStart..<(clampedStart + clampedRemoved))
        result.insert(contentsOf: inserted, at: clampedStart)
        return result
    }

    /// 装配成节点。
    ///
    /// 默认收起、只显示一行摘要——队列里通常是用户连打的几条消息，
    /// 展开占屏幕但信息量低。
    ///
    /// - Parameter filter: 用来过滤队列条目的来源。队列里也混着注入。
    public func nodes(seq: EventSeq, filter: UserMessageFilter) -> [InboxNode] {
        var result: [InboxNode] = []
        let step = visibleEntries(nextStep, filter: filter)
        if !step.isEmpty {
            result.append(
                InboxNode(seq: seq, kind: .nextStep, summary: Self.summary(step, label: "下一步"))
            )
        }
        let turn = visibleEntries(nextTurn, filter: filter)
        if !turn.isEmpty {
            result.append(
                InboxNode(seq: seq, kind: .nextTurn, summary: Self.summary(turn, label: "下一轮"))
            )
        }
        return result
    }

    /// 队列里该显示给用户的那些条目。
    func visibleEntries(_ entries: [Entry], filter: UserMessageFilter) -> [Entry] {
        entries.filter { filter.shouldRender(sourceKind: $0.sourceKind) }
    }

    /// 一行摘要。
    static func summary(_ entries: [Entry], label: String) -> String {
        guard let first = entries.first else { return "" }
        let head = TextSummary.oneLine(first.text, limit: 60)
        if entries.count == 1 {
            return "\(label)：\(head)"
        }
        return "\(label)：\(head) 等 \(entries.count) 条"
    }

    /// 两条队列里可见条目的总数。用来决定输入条上要不要显示"排队中 N 条"。
    public func visibleCount(filter: UserMessageFilter) -> Int {
        visibleEntries(nextStep, filter: filter).count
            + visibleEntries(nextTurn, filter: filter).count
    }
}
