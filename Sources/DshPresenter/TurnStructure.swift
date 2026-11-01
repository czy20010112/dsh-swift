import DshSession

/// 一轮对话的结束原因。
///
/// 五种取值全部来自实测（326 个会话 / 1,265 次 `turn/end`）：
/// `completed` 1,020 / `aborted` 138 / `error` 77 / `interrupted` 17 / `max-tokens` 13。
///
/// 为什么要建模而不是忽略：非 `completed` 的占 **19.4%**，接近五分之一。
/// 不显示结束原因的话，用户看到回答戛然而止却不知道是被打断、出错还是撞了 token 上限。
public enum TurnEndReason: Sendable, Equatable {
    /// 正常跑完。
    case completed
    /// 被中止。`reason` 字段说明是什么中止的。
    case aborted(String?)
    /// 出错。`error` 字段带详情。
    case error(String?)
    /// 用户打断。
    case interrupted
    /// 撞上 token 上限。这一轮的回答是不完整的。
    case maxTokens
    /// 没见过的原因。不猜，原样显示。
    case unknown(String)

    /// 这一轮是否正常结束。非正常结束要在轮次尾给出提示。
    public var isClean: Bool {
        if case .completed = self { return true }
        return false
    }

    public init(kind: String, detail: String?) {
        switch kind {
        case "completed": self = .completed
        case "aborted": self = .aborted(detail)
        case "error": self = .error(detail)
        case "interrupted": self = .interrupted
        case "max-tokens": self = .maxTokens
        default: self = .unknown(kind)
        }
    }
}

/// 轮次与步骤的边界。
///
/// 这是把所有节点串起来的骨架：每个事件都带 `(turn, step)`，节点靠它归属到
/// 正确的轮次里，折叠也以轮为单位。
///
/// 规模依据：每轮的 step 数 p50=14 / p90=84 / p99=236 / max=401。
/// 单轮事件数 p50=107 / p90=684 / max=15,698。所以"整轮折叠"不是锦上添花——
/// p90 那些轮次展开后有几百个节点。
public struct TurnStructure: Sendable, Equatable {

    /// 一个步骤。agent 的一次"思考 + 行动"循环。
    public struct Step: Sendable, Equatable {
        public var index: Int
        public var startSeq: EventSeq
        /// 还在进行中时为 nil。
        public var endSeq: EventSeq?

        public init(index: Int, startSeq: EventSeq, endSeq: EventSeq?) {
            self.index = index
            self.startSeq = startSeq
            self.endSeq = endSeq
        }

        public var isClosed: Bool { endSeq != nil }
    }

    /// 一轮。用户发一次消息到 agent 交还控制权。
    public struct Turn: Sendable, Equatable {
        public var index: Int
        public var startSeq: EventSeq
        public var endSeq: EventSeq?
        public var reason: TurnEndReason?
        public var steps: [Step]

        public init(
            index: Int,
            startSeq: EventSeq,
            endSeq: EventSeq?,
            reason: TurnEndReason?,
            steps: [Step]
        ) {
            self.index = index
            self.startSeq = startSeq
            self.endSeq = endSeq
            self.reason = reason
            self.steps = steps
        }

        /// 轮次是否已结束。
        ///
        /// **进行中的轮次不能折叠**——用户正在看它。折叠判定要读这个。
        public var isClosed: Bool { endSeq != nil }
    }

    public private(set) var turns: [Turn] = []

    public init() {}

    /// 处理一条 `turn/start`。
    ///
    /// 重复的 start（重连后 snapshot 与增量重叠）不新建轮次，幂等。
    public mutating func startTurn(index: Int, seq: EventSeq) {
        guard !turns.contains(where: { $0.index == index }) else { return }
        turns.append(Turn(index: index, startSeq: seq, endSeq: nil, reason: nil, steps: []))
        turns.sort { $0.index < $1.index }
    }

    /// 处理一条 `turn/end`。
    public mutating func endTurn(index: Int, seq: EventSeq, reason: TurnEndReason) {
        guard let position = turns.firstIndex(where: { $0.index == index }) else { return }
        turns[position].endSeq = seq
        turns[position].reason = reason
    }

    /// 处理一条 `step/start`。
    ///
    /// 如果所属轮次还没见过（事件乱序，或窗口从中间开始），**先补一个轮次**——
    /// 丢掉这个 step 会让它的节点无处归属，整段内容从界面上消失。
    public mutating func startStep(turn: Int, step: Int, seq: EventSeq) {
        if !turns.contains(where: { $0.index == turn }) {
            // 窗口可能从轮次中间开始（分页取历史时很常见），用 step 的 seq 当轮次起点
            startTurn(index: turn, seq: seq)
        }
        guard let position = turns.firstIndex(where: { $0.index == turn }) else { return }
        guard !turns[position].steps.contains(where: { $0.index == step }) else { return }
        turns[position].steps.append(Step(index: step, startSeq: seq, endSeq: nil))
        turns[position].steps.sort { $0.index < $1.index }
    }

    /// 处理一条 `step/end`。
    public mutating func endStep(turn: Int, step: Int, seq: EventSeq) {
        guard let turnPosition = turns.firstIndex(where: { $0.index == turn }),
              let stepPosition = turns[turnPosition].steps.firstIndex(where: { $0.index == step })
        else { return }
        turns[turnPosition].steps[stepPosition].endSeq = seq
    }

    /// 某个 seq 落在哪一轮。
    ///
    /// 用于把节点归属到轮次。进行中的轮次没有 endSeq，所以它吃掉它 startSeq 之后的一切。
    public func turn(containing seq: EventSeq) -> Turn? {
        // 从后往前找：最近的轮次最可能命中，而且进行中的轮次在最后
        for turn in turns.reversed() where seq >= turn.startSeq {
            if let end = turn.endSeq {
                if seq <= end { return turn }
            } else {
                return turn  // 进行中
            }
        }
        return nil
    }

    /// 最后一轮。进行中的那一轮通常就是它。
    public var lastTurn: Turn? { turns.last }

    /// 有没有正在进行的轮次。决定要不要显示"停止"按钮。
    public var hasOpenTurn: Bool { turns.contains { !$0.isClosed } }
}
