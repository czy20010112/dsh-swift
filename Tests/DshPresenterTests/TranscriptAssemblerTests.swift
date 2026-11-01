import XCTest
@testable import DshPresenter
@testable import DshSession

/// 装配链里的跨事件关联。
///
/// 回放测试证明"真实会话能装配"；这里用手写的小序列把每条关联规则单独钉住，
/// 出错时能直接看出是哪条规则坏了。
final class TranscriptAssemblerTests: XCTestCase {

    private let assembler = TranscriptAssembler()

    private func event(_ seq: EventSeq, _ type: String, _ payload: EventPayload, op: SurfaceOp? = nil) -> SessionEvent {
        SessionEvent(seq: seq, time: 0, type: type, surfaceOp: op, sourceEventSeqs: [], payload: payload)
    }

    private func message(_ text: String, source: String = "user") -> EventPayload {
        .message(ConversationMessage(role: "user", sourceKind: source, text: text))
    }

    private func reasoningRun(_ texts: [String], time0: Int64 = 0, dt: [Int]? = nil) -> StreamItem {
        StreamItem(run: .reasoning(ChunkRun(
            index: 0, time0: time0, dt: dt ?? Array(repeating: 10, count: max(0, texts.count - 1)), texts: texts
        )))
    }

    // MARK: - 斜杠命令

    /// run 和 done 按 commandId 合成一个节点。
    func testCommandRunAndDoneMerge() {
        let out = assembler.assemble([
            event(1, "command/run", .commandRun(commandId: "c1", name: "permission", args: " auto")),
            event(2, "command/done", .commandDone(commandId: "c1", kind: "success", text: "preset auto")),
        ])
        XCTAssertEqual(out.nodes.count, 1)
        guard case .command(let node) = out.nodes[0] else { return XCTFail("应该是命令节点") }
        XCTAssertEqual(node.outcome, "success")
        XCTAssertEqual(node.outcomeText, "preset auto")
        XCTAssertEqual(node.seq, 1, "节点留在命令执行的位置")
    }

    /// args 在线上带前导空格（实测 `" danger-full-access"`）。
    func testCommandDisplayLineTrimsArgs() {
        let node = CommandNode(seq: 1, commandId: "c", name: "permission", args: " danger-full-access")
        XCTAssertEqual(node.displayLine, "/permission danger-full-access")
    }

    func testCommandWithoutArgs() {
        XCTAssertEqual(CommandNode(seq: 1, commandId: "c", name: "compact", args: nil).displayLine, "/compact")
        XCTAssertEqual(CommandNode(seq: 1, commandId: "c", name: "compact", args: "  ").displayLine, "/compact")
    }

    /// 窗口从中间开始时 run 不在窗口里。结果不能丢，它本身就是用户要看的。
    func testCommandDoneWithoutRunStillShows() {
        let out = assembler.assemble([
            event(5, "command/done", .commandDone(commandId: "lost", kind: "error", text: "未知命令")),
        ])
        guard case .command(let node)? = out.nodes.first else { return XCTFail("结果被丢掉了") }
        XCTAssertEqual(node.outcomeText, "未知命令")
    }

    // MARK: - 工具

    /// assistant 消息里的 tool-call 块不出节点，以 tool/call 事件为准。
    func testToolCallBlockInMessageDoesNotDuplicateCard() {
        let out = assembler.assemble([
            event(1, "assistant/message", .assistantMessage(AssistantMessageEvent(
                turn: 1, step: 1,
                content: [.text("我看一下"), .toolCall(id: "t1", name: "read", arguments: "{}")],
                stream: [], usage: nil, model: nil
            )), op: .append),
            event(2, "tool/call", .toolCall(ToolCallEvent(turn: 1, step: 1, callId: "t1", name: "read", arguments: "{}"))),
        ])
        let cards = out.nodes.filter { if case .tool = $0 { return true }; return false }
        XCTAssertEqual(cards.count, 1)
    }

    /// 第二个结果带 replace，是模型侧的改写副本。卡上必须是 append 那份。
    func testReplacedResultDoesNotOverwriteCard() {
        let out = assembler.assemble([
            event(1, "tool/call", .toolCall(ToolCallEvent(turn: 1, step: 1, callId: "t1", name: "read", arguments: "{}"))),
            event(2, "tool/result", .toolResult(ToolResultEvent(
                turn: 1, step: 1, callId: "t1", callIdOrigin: .messageToolCallId,
                text: "原始完整输出", isError: false, imageCount: 0
            )), op: .append),
            event(3, "tool/result", .toolResult(ToolResultEvent(
                turn: 1, step: 1, callId: "t1", callIdOrigin: .messageToolCallId,
                text: "[已裁剪]", isError: false, imageCount: 0
            )), op: .replace(startSeq: 2, endSeq: 2)),
        ])
        guard case .tool(let card)? = out.nodes.first else { return XCTFail() }
        XCTAssertEqual(card.resultText, "原始完整输出")
    }

    func testOrphanResultIsCounted() {
        let out = assembler.assemble([
            event(1, "tool/result", .toolResult(ToolResultEvent(
                turn: 1, step: 1, callId: "ghost", callIdOrigin: .sourceCallId,
                text: "x", isError: false, imageCount: 0
            )), op: .append),
        ])
        XCTAssertEqual(out.orphanToolResults, 1)
        XCTAssertTrue(out.nodes.isEmpty)
    }

    // MARK: - 思考

    /// v0：思考分片是独立的顶层行，排在消息之前，要归到下一条消息上。
    func testV0TopLevelReasoningAttachesToNextMessage() {
        let out = assembler.assemble([
            event(1, "reasoning-chunks", .stream(reasoningRun(["想", "一想"], time0: 1000, dt: [500]))),
            event(3, "assistant/message", .assistantMessage(AssistantMessageEvent(
                turn: 1, step: 1, content: [.reasoning("想一想"), .text("好的")],
                stream: [], usage: nil, model: nil
            )), op: .append),
        ])
        guard case .reasoning(let node)? = out.nodes.first else { return XCTFail("没有思考节点") }
        XCTAssertEqual(node.text, "想一想")
        XCTAssertEqual(node.duration, 0.5, accuracy: 0.001, "时长来自顶层 run 的 dt")
    }

    /// 被重试作废的生成，它攒下的思考不能挂到重试成功的那条消息上。
    func testAbandonedAttemptDiscardsPendingReasoning() {
        let out = assembler.assemble([
            event(1, "reasoning-chunks", .stream(reasoningRun(["作废的"], time0: 0, dt: []))),
            event(2, "assistant/attempt", .assistantAttempt(AssistantAttemptEvent(turn: 1, step: 1, stream: []))),
            event(3, "assistant/message", .assistantMessage(AssistantMessageEvent(
                turn: 1, step: 1, content: [.text("成功的回答")], stream: [], usage: nil, model: nil
            )), op: .append),
        ])
        let hasReasoning = out.nodes.contains { if case .reasoning = $0 { return true }; return false }
        XCTAssertFalse(hasReasoning, "作废那次的思考挂到了成功的回答上")
    }

    // MARK: - 重试

    /// 1/5 到 5/5 合成一个节点，只显示最新次数。
    func testConsecutiveRetriesCollapse() {
        var events: [SessionEvent] = []
        for attempt in 1...5 {
            events.append(event(EventSeq(attempt * 3), "llm/retry", .llmRetry(LLMRetryEvent(
                turn: 1, step: 1, attempt: attempt, maxAttempts: 5,
                failureCode: "TRANSPORT", failureMessage: "Connection error."
            ))))
            events.append(event(EventSeq(attempt * 3 + 1), "llm/retry-started", .unknown(type: "llm/retry-started")))
        }
        let out = assembler.assemble(events)
        XCTAssertEqual(out.nodes.count, 1)
        guard case .retry(let notice)? = out.nodes.first else { return XCTFail() }
        XCTAssertEqual(notice.summary, "重试 5/5 · 连接中断")
    }

    /// 新一轮重试从 1 重新开始时要另起一个节点，不能并进上一轮。
    func testNewRetryRoundStartsNewNode() {
        let out = assembler.assemble([
            event(1, "llm/retry", .llmRetry(LLMRetryEvent(turn: 1, step: 1, attempt: 5, maxAttempts: 5, failureCode: "TRANSPORT", failureMessage: nil))),
            event(2, "llm/retry", .llmRetry(LLMRetryEvent(turn: 1, step: 2, attempt: 1, maxAttempts: 5, failureCode: "TRANSPORT", failureMessage: nil))),
        ])
        XCTAssertEqual(out.nodes.count, 2)
    }

    // MARK: - 用户行与排队

    func testInjectedUserMessageIsHidden() {
        let out = assembler.assemble([
            event(1, "user/message", message("真人发言"), op: .append),
            event(2, "user/message", message("<runtime context>", source: "runtime-context"), op: .append),
        ])
        XCTAssertEqual(out.nodes.count, 1)
    }

    func testInboxSpliceGoesToQueueNotTranscript() {
        let out = assembler.assemble([
            event(1, "agent/inbox/spliced", .inboxSplice(InboxSpliceEvent(
                target: "next-turn", start: 0, removedCount: 0,
                inserted: [ConversationMessage(role: "user", sourceKind: "user", text: "排队的话")]
            ))),
        ])
        XCTAssertTrue(out.nodes.isEmpty, "排队消息不进正文")
        XCTAssertEqual(out.inbox.nextTurn.map(\.text), ["排队的话"])
    }

    // MARK: - 压缩

    func testCheckpointBecomesMarkerAndKeepsHistory() {
        let out = assembler.assemble([
            event(1, "user/message", message("早先的问题"), op: .append),
            event(2, "assistant/message", .assistantMessage(AssistantMessageEvent(
                turn: 1, step: 1, content: [.text("早先的回答")], stream: [], usage: nil, model: nil
            )), op: .append),
            event(3, "user/message", .message(ConversationMessage(
                role: "user", sourceKind: "compact-checkpoint", compactionId: "k", text: "# 摘要"
            )), op: .replace(startSeq: 1, endSeq: 2)),
        ])
        XCTAssertEqual(out.nodes.count, 3, "两条历史 + 一个压缩标记")
        if case .compaction = out.nodes[2] {} else { XCTFail("最后一个应该是压缩标记") }
    }

    // MARK: - 待办

    func testTodoSummaryCountsCompleted() {
        let node = TodoNode(seq: 1, items: [
            TodoItem(content: "a", status: "completed"),
            TodoItem(content: "b", status: "in_progress"),
            TodoItem(content: "c", status: "pending"),
        ])
        XCTAssertEqual(node.summary, "待办 1/3")
    }

    // MARK: - 流式标记

    func testStreamingTurnMarksLastNode() {
        let out = assembler.assemble([
            event(1, "turn/start", .turnStart(turn: 1)),
            event(2, "assistant/message", .assistantMessage(AssistantMessageEvent(
                turn: 1, step: 1, content: [.text("写到一半")], stream: [], usage: nil, model: nil
            )), op: .append),
        ], streamingTurn: 1)
        guard case .assistant(let node)? = out.nodes.last else { return XCTFail() }
        XCTAssertTrue(node.isStreaming)
    }

    /// 已结束的轮次不标流式，即使调用方传了它。
    func testClosedTurnIsNotStreaming() {
        let out = assembler.assemble([
            event(1, "turn/start", .turnStart(turn: 1)),
            event(2, "assistant/message", .assistantMessage(AssistantMessageEvent(
                turn: 1, step: 1, content: [.text("完整回答")], stream: [], usage: nil, model: nil
            )), op: .append),
            event(3, "turn/end", .turnEnd(turn: 1, reason: "completed")),
        ], streamingTurn: 1)
        guard case .assistant(let node)? = out.nodes.last else { return XCTFail() }
        XCTAssertFalse(node.isStreaming)
    }
}
