import DshSession

/// 把思考分片装配成 `.reasoning` 节点。
///
/// 为什么这是装配器的第一块实料：`reasoning-chunks` 占全部事件的 **44.3%**
/// （326 个会话 523,473 条事件里有 231,948 条），占正文体积的 **94.3%**。
/// 它既是最常见的东西，也是流式渲染的性能主路径。
///
/// 设计上的两条结论直接来自这个比例：
///
/// 1. **默认收起成一行摘要**。展开才渲染全文。如果默认展开，用户每轮要先滚过
///    几千字思考才能看到结论——实测单轮思考的中位数就有数千字。
/// 2. **流式期间只更新计数器，不重排版面**。收起态显示的是"思考 12.4 秒 · 3,400 字"，
///    这两个数字变化不影响 cell 高度，所以可以每帧更新而不触发布局。
///    全文的排版只在展开时发生一次。
public struct ReasoningAssembler: Sendable {

    public init() {}

    /// 一个思考块的累加状态。
    ///
    /// 按 `(turn, step, index)` 分组：`index` 是**内容块身份**，不是分片序号，
    /// 所以同一个块的多条 run 要累加到一起。
    public struct BlockKey: Hashable, Sendable {
        public var turn: Int
        public var step: Int
        public var index: Int

        public init(turn: Int, step: Int, index: Int) {
            self.turn = turn
            self.step = step
            self.index = index
        }
    }

    /// 把属于同一个思考块的多条 run 合成一个节点。
    ///
    /// - Parameters:
    ///   - seq: 节点在窗口里的位置。
    ///   - runs: 按到达顺序排列的 run。同一块可能被切成多条（流式分批落盘）。
    ///   - isStreaming: 这个块是否还在增长。流式中的块不做精确测高。
    public func assemble(
        seq: EventSeq,
        runs: [ChunkRun],
        isStreaming: Bool
    ) -> ReasoningNode {
        let text = runs.map(AssistantStream.joinedText).joined()
        let totalMilliseconds = runs.reduce(0) { $0 + AssistantStream.duration($1) }

        // 跨 run 的间隔也算进思考时间：两条 run 之间有真实的等待。
        let gapMilliseconds = Self.gaps(between: runs)

        return ReasoningNode(
            seq: seq,
            text: text,
            // 用字素簇计数，不用 UTF-16 code unit。中文、emoji、组合字符在
            // UTF-16 下的长度和"用户看到几个字"完全不是一回事。
            characterCount: text.count,
            duration: Double(totalMilliseconds + gapMilliseconds) / 1000.0,
            isStreaming: isStreaming
        )
    }

    /// 多条 run 之间的空档时间。
    ///
    /// 每条 run 自己的 `dt` 只覆盖它内部的分片间隔；run A 的最后一片到
    /// run B 的第一片之间还有一段时间，不算进去会低估思考耗时。
    static func gaps(between runs: [ChunkRun]) -> Int {
        guard runs.count > 1 else { return 0 }
        var total = 0
        for (previous, next) in zip(runs, runs.dropFirst()) {
            let previousEnd = previous.time0 + Int64(AssistantStream.duration(previous))
            let gap = next.time0 - previousEnd
            // 负值说明 run 的顺序和时间不一致（乱序到达），按 0 处理而不是减时间。
            if gap > 0 { total += Int(gap) }
        }
        return total
    }

    /// 收起态显示的那一行。
    ///
    /// 流式中与已完成的文案不同：流式中说"思考中"，因为耗时还在变。
    public func collapsedSummary(_ node: ReasoningNode) -> String {
        let characters = Self.formatCount(node.characterCount)
        if node.isStreaming {
            return "思考中 · \(characters) 字"
        }
        if node.duration < 0.1 {
            return "思考 · \(characters) 字"
        }
        return "思考 \(Self.formatDuration(node.duration)) · \(characters) 字"
    }

    /// 字数的紧凑写法。见 `TextSummary.compactCount`。
    static func formatCount(_ count: Int) -> String {
        TextSummary.compactCount(count)
    }

    /// 耗时的紧凑写法。见 `TextSummary.compactDuration`。
    static func formatDuration(_ seconds: Double) -> String {
        TextSummary.compactDuration(seconds)
    }
}
