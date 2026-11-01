import DshSession

/// 一整份会话事件 → 正文节点列表。
///
/// 前面各个装配器（思考、工具、正文、用户行、排队）各管一类节点；这里把它们
/// 按事件顺序串起来，并处理跨事件的关联：工具结果挂回调用、v0 的顶层流分片
/// 归到它们所属的 assistant 消息、replace 副本不进正文。
///
/// **当前是整窗重算**：每次给一份完整的事件数组，从头装配。实测单会话 p90 有
/// 4,316 个事件、max 48,603，在手机上用 60 ms 节流整窗重算是够的；增量装配
/// 等真的测到性能问题再做。
public struct TranscriptAssembler: Sendable {

    public init() {}

    /// 装配结果。
    public struct Output: Sendable {
        public var nodes: [ChatNode]
        /// 轮次骨架。渲染层用它做"整轮折叠"和"停止"按钮。
        public var turns: TurnStructure
        /// 排队中的输入。显示在输入框上方，不在正文里。
        public var inbox: InboxQueue
        /// 配不上调用的工具结果个数。实测 v3 会话里会出现（host 丢过事件），
        /// 不是解码错误，但值得在诊断信息里露出来。
        public var orphanToolResults: Int
    }

    /// 装配一份完整的事件序列。
    ///
    /// - Parameter streamingTurn: 正在进行的轮次。该轮最后一条思考/正文标成流式，
    ///   渲染层据此不做精确测高。离线回放传 nil。
    public func assemble(_ events: [SessionEvent], streamingTurn: Int? = nil) -> Output {
        var state = State()
        let ordered = events.sorted { $0.seq < $1.seq }
        for event in ordered {
            state.consume(event)
        }
        state.finish(streamingTurn: streamingTurn)
        return Output(
            nodes: state.nodes,
            turns: state.turns,
            inbox: state.inbox,
            orphanToolResults: state.orphanToolResults
        )
    }

    // MARK: - 状态机

    private struct State {
        var nodes: [ChatNode] = []
        var turns = TurnStructure()
        var inbox = InboxQueue()
        var orphanToolResults = 0

        /// callId → 工具节点在 `nodes` 里的下标。结果按 callId 挂回去，不靠顺序。
        var toolIndex: [String: Int] = [:]
        /// 还没被 assistant/message 收走的 v0 顶层思考 run。
        ///
        /// v0 的流分片是独立的顶层行，排在它们所属的 assistant/message **之前**；
        /// v3/v4 把同样的东西嵌在 message 的 `stream` 字段里。两种都归到下一条消息。
        var pendingReasoning: [ChunkRun] = []

        let tools = ToolAssembler()
        let reasoning = ReasoningAssembler()
        let users = UserMessageFilter()

        mutating func consume(_ event: SessionEvent) {
            // replace 出来的副本只给模型看。进正文会让同一个工具显示两份结果、
            // 或者把压缩摘要当成用户发言（见 SurfaceRole）。
            let role = event.surfaceRole
            if case .compactionCheckpoint = role {
                nodes.append(.compaction(CompactionNode(seq: event.seq)))
                return
            }
            guard role.entersTranscript else { return }

            switch event.payload {
            case .turnStart(let turn):
                turns.startTurn(index: turn, seq: event.seq)
            case .turnEnd(let turn, let reason):
                turns.endTurn(index: turn, seq: event.seq, reason: TurnEndReason(kind: reason ?? "", detail: nil))
            case .stepStart(let turn, let step):
                turns.startStep(turn: turn, step: step, seq: event.seq)
            case .stepEnd(let turn, let step):
                turns.endStep(turn: turn, step: step, seq: event.seq)

            case .stream(let item):
                // v0 的顶层分片。只收思考 run——正文以 message.content 为准，
                // 工具参数以 tool/call 为准，它们的流分片在离线装配里是冗余的。
                if case .reasoning(let run) = item.run { pendingReasoning.append(run) }

            case .assistantMessage(let message):
                appendAssistant(message, seq: event.seq)

            case .assistantAttempt:
                // 被重试作废的那次生成。用户看到的是重试成功后的那份。
                pendingReasoning.removeAll()

            case .toolCall(let call):
                toolIndex[call.callId] = nodes.count
                let assembled = tools.assemble(
                    calls: [ToolAssembler.Call(seq: event.seq, callId: call.callId, name: call.name, arguments: call.arguments)],
                    results: [:]
                )
                nodes.append(contentsOf: assembled.map(ChatNode.tool))

            case .toolResult(let result):
                attach(result)

            case .message(let message):
                appendMessage(message, type: event.type, seq: event.seq)

            case .inboxSplice(let splice):
                // 队列显示在输入框上方，不在正文里：这里只重放 splice
                inbox.splice(
                    target: InboxQueue.Target(raw: splice.target),
                    start: splice.start,
                    removedCount: splice.removedCount,
                    inserted: splice.inserted.map {
                        InboxQueue.Entry(id: nil, sourceKind: $0.sourceKind, text: $0.text)
                    }
                )

            case .llmRetry(let retry):
                appendRetry(retry, seq: event.seq)

            case .unknown(let type):
                appendUnknown(type: type, event: event)
            }
        }

        mutating func appendAssistant(_ message: AssistantMessageEvent, seq: EventSeq) {
            // 思考时长只有流分片里有（dt）；文本以 content 为准。
            // v3/v4 用 message 自带的 stream，v0 用之前攒下的顶层 run。
            var runs = message.stream.compactMap { item -> ChunkRun? in
                if case .reasoning(let run) = item.run { return run }
                return nil
            }
            if runs.isEmpty { runs = pendingReasoning }
            pendingReasoning.removeAll()

            let reasoningText = message.content.compactMap { block -> String? in
                if case .reasoning(let text) = block { return text }
                return nil
            }.joined()
            if !reasoningText.isEmpty || !runs.isEmpty {
                var node = reasoning.assemble(seq: seq, runs: runs, isStreaming: false)
                // content 里的思考全文比流分片可靠（流分片可能被截断或缺失）
                if !reasoningText.isEmpty {
                    node.text = reasoningText
                    node.characterCount = reasoningText.count
                }
                nodes.append(.reasoning(node))
            }

            let text = message.content.compactMap { block -> String? in
                if case .text(let text) = block { return text }
                return nil
            }.joined(separator: "\n\n")
            if !text.isEmpty {
                nodes.append(.assistant(AssistantNode(seq: seq, markdown: text, isStreaming: false)))
            }
            // tool-call 块不在这里出节点：同一次调用还会有一条 tool/call 事件，
            // 以那条为准（它有完整参数和 callId）。两处都出就会显示两张卡。
        }

        mutating func attach(_ result: ToolResultEvent) {
            guard let callId = result.callId, let index = toolIndex[callId],
                  case .tool(var node) = nodes[index] else {
                orphanToolResults += 1
                return
            }
            node.resultText = result.text
            node.isError = result.isError
            nodes[index] = .tool(node)
        }

        mutating func appendMessage(_ message: ConversationMessage, type: String, seq: EventSeq) {
            // system / developer 消息是给模型的指令，正文不显示（轨迹视图里看）。
            guard type == "user/message" else { return }
            if let node = users.node(seq: seq, sourceKind: message.sourceKind, texts: [message.text]) {
                nodes.append(.user(node))
            }
        }

        mutating func appendRetry(_ retry: LLMRetryEvent, seq: EventSeq) {
            let notice = RetryNotice(
                seq: seq,
                code: retry.failureCode,
                message: retry.failureMessage,
                attempt: retry.attempt,
                maxAttempts: retry.maxAttempts
            )
            // 连续重试只留最新一条：第 1/5、2/5、3/5 三条并排没有信息量，
            // 用户关心的是"现在到第几次了、为什么"。
            if case .retry(let previous)? = nodes.last,
               previous.code == notice.code, previous.attempt < notice.attempt {
                nodes[nodes.count - 1] = .retry(notice)
            } else {
                nodes.append(.retry(notice))
            }
        }

        mutating func appendUnknown(type: String, event: SessionEvent) {
            // 解码器没建模的类型。只有分类器认为"有正文后果"的才出占位节点，
            // 其余（插件事件、请求头……）安静地跳过。
            guard EventClassifier.producesNode(type) else { return }
            nodes.append(.unknown(UnknownNode(seq: event.seq, type: type)))
        }

        mutating func finish(streamingTurn: Int?) {
            guard let streamingTurn,
                  let turn = turns.turns.first(where: { $0.index == streamingTurn }),
                  !turn.isClosed else { return }
            // 进行中的轮次：最后一条思考或正文还在增长
            for i in nodes.indices.reversed() {
                guard nodes[i].seq >= turn.startSeq else { break }
                switch nodes[i] {
                case .reasoning(var node):
                    node.isStreaming = true
                    nodes[i] = .reasoning(node)
                    return
                case .assistant(var node):
                    node.isStreaming = true
                    nodes[i] = .assistant(node)
                    return
                default:
                    continue
                }
            }
        }
    }
}

extension ChatNode {
    /// 节点在事件流里的位置。
    public var seq: EventSeq {
        switch self {
        case .user(let n): return n.seq
        case .reasoning(let n): return n.seq
        case .tool(let n): return n.seq
        case .assistant(let n): return n.seq
        case .turnTail(let n): return n.seq
        case .inbox(let n): return n.seq
        case .compaction(let n): return n.seq
        case .retry(let n): return n.seq
        case .unknown(let n): return n.seq
        }
    }
}
