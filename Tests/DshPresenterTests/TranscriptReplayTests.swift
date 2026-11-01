import Foundation
import XCTest
@testable import DshPresenter
@testable import DshSession

/// 整条装配链的端到端回放：真实会话事件 → `[ChatNode]`。
///
/// 前面每个装配器都有自己的单测，但它们之间的衔接（v0 顶层分片归到哪条消息、
/// 结果挂回哪张卡、replace 副本有没有漏进正文）只有喂真实会话才测得到。
///
/// 夹具是 `Tests/Fixtures/` 下 15 份脱敏后的真实会话，三代格式都有。
final class TranscriptReplayTests: XCTestCase {

    private struct Fixture: Decodable {
        var name: String
        var events: [LossyDecoded<SessionEvent>]
    }

    private struct Manifest: Decodable {
        struct Entry: Decodable {
            var file: String
            var generation: String
        }
        var fixtures: [Entry]
    }

    private struct Replayed {
        var file: String
        var generation: String
        var events: [SessionEvent]
        var output: TranscriptAssembler.Output
    }

    private static let fixturesDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")

    /// 只装配一次。15 份夹具共约 1.6 MB。
    private static let replayed: Result<[Replayed], Error> = Result {
        let manifestData = try Data(contentsOf: fixturesDir.appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        let assembler = TranscriptAssembler()
        return try manifest.fixtures.map { entry in
            let data = try Data(contentsOf: fixturesDir.appendingPathComponent(entry.file))
            let events = try JSONDecoder().decode(Fixture.self, from: data).events.compactMap(\.value)
            return Replayed(
                file: entry.file,
                generation: entry.generation,
                events: events,
                output: assembler.assemble(events)
            )
        }
    }

    private func all() throws -> [Replayed] {
        let r = try Self.replayed.get()
        XCTAssertFalse(r.isEmpty)
        return r
    }

    // MARK: - 每份会话都能出东西

    /// 每份夹具都要装配出至少一个节点。空正文意味着某一代格式整个没接上。
    func testEveryFixtureProducesNodes() throws {
        for r in try all() {
            XCTAssertFalse(r.output.nodes.isEmpty, "\(r.file)(\(r.generation)): 装配结果为空")
        }
    }

    /// 三代格式都要能出思考、工具、正文三类主力节点。
    /// 任何一代缺了某一类，说明那一代的字段位置没接对。
    func testEveryGenerationProducesCoreNodeKinds() throws {
        var kinds: [String: Set<String>] = [:]
        for r in try all() {
            for node in r.output.nodes {
                kinds[r.generation, default: []].insert(Self.kind(node))
            }
        }
        for generation in ["v0", "v3", "v4"] {
            let seen = kinds[generation] ?? []
            for required in ["reasoning", "tool", "assistant"] {
                XCTAssertTrue(seen.contains(required), "\(generation) 没有装配出 \(required) 节点，实际: \(seen.sorted())")
            }
        }
    }

    // MARK: - 顺序

    /// 节点必须按 seq 单调排列。乱序会让回答出现在它所回应的问题之前。
    func testNodesAreInSeqOrder() throws {
        for r in try all() {
            let seqs = r.output.nodes.map(\.seq)
            XCTAssertEqual(seqs, seqs.sorted(), "\(r.file): 节点乱序")
        }
    }

    // MARK: - 用户行

    /// 正文里的用户行只能来自白名单来源。这是"假用户气泡刷屏"的直接检查。
    func testUserNodesOnlyFromWhitelistedSources() throws {
        for r in try all() {
            let allowedSeqs = Set(r.events.compactMap { event -> EventSeq? in
                guard case .message(let m) = event.payload, event.type == "user/message",
                      UserMessageFilter.renderedSources.contains(m.sourceKind ?? "") else { return nil }
                return event.seq
            })
            for node in r.output.nodes {
                guard case .user(let user) = node else { continue }
                XCTAssertTrue(allowedSeqs.contains(user.seq), "\(r.file) seq \(user.seq): 注入消息被渲染成了用户发言")
            }
        }
    }

    // MARK: - 工具

    /// 每个 tool/call 都恰好出一张卡。两张意味着 assistant/message 的 tool-call 块
    /// 和 tool/call 事件被各算了一次。
    func testOneCardPerToolCall() throws {
        for r in try all() {
            let calls = r.events.filter { $0.type == "tool/call" }.count
            let cards = r.output.nodes.filter { if case .tool = $0 { return true }; return false }.count
            XCTAssertEqual(cards, calls, "\(r.file): 工具卡数与 tool/call 数不符")
        }
    }

    /// replace 副本不能进正文：一个调用的第二个结果总带 replace，进正文的话
    /// 同一张卡的结果会被模型侧的改写版本覆盖。这里检查：卡上的结果文本来自
    /// append 来源的结果。
    func testToolResultsComeFromAppendOrigin() throws {
        for r in try all() {
            var appendText: [String: String] = [:]
            for event in r.events {
                guard case .toolResult(let result) = event.payload, let id = result.callId,
                      event.surfaceRole == .transcript else { continue }
                appendText[id] = appendText[id] ?? result.text
            }
            var callIds: [EventSeq: String] = [:]
            for event in r.events {
                if case .toolCall(let call) = event.payload { callIds[event.seq] = call.callId }
            }
            for node in r.output.nodes {
                guard case .tool(let tool) = node, let id = callIds[tool.seq],
                      let expected = appendText[id] else { continue }
                XCTAssertEqual(tool.resultText, expected, "\(r.file) call \(id): 结果被 replace 副本覆盖")
            }
        }
    }

    /// 配不上调用的结果只应该出现在 v3（host 丢过事件，见 PITFALLS 第 28 条）。
    /// v0 / v4 出现孤儿说明配对字段取错了位置。
    func testOrphanResultsOnlyInV3() throws {
        for r in try all() where r.generation != "v3" {
            XCTAssertEqual(r.output.orphanToolResults, 0, "\(r.file)(\(r.generation)): 有配不上的工具结果")
        }
    }

    /// 绝大多数调用要拿到结果。比例太低说明配对整体失效。
    func testMostToolCallsGetResults() throws {
        var total = 0, withResult = 0
        for r in try all() {
            for node in r.output.nodes {
                guard case .tool(let tool) = node else { continue }
                total += 1
                if tool.resultText != nil { withResult += 1 }
            }
        }
        XCTAssertGreaterThan(total, 0)
        let ratio = Double(withResult) / Double(total)
        XCTAssertGreaterThan(ratio, 0.9, "只有 \(withResult)/\(total) 个工具调用拿到了结果")
        print("[transcript] 工具调用 \(total)，拿到结果 \(withResult)（\(Int(ratio * 100))%）")
    }

    // MARK: - 思考

    /// v0 的思考在顶层分片里、v3/v4 在 message.stream 里。两代都要能归到消息上，
    /// 并且有可测量的时长——时长只能从流分片的 dt 算出来。
    func testReasoningHasDurationInEveryGeneration() throws {
        var timed: [String: Int] = [:]
        for r in try all() {
            for node in r.output.nodes {
                guard case .reasoning(let n) = node, n.duration > 0 else { continue }
                timed[r.generation, default: 0] += 1
            }
        }
        for generation in ["v0", "v3", "v4"] {
            XCTAssertGreaterThan(timed[generation] ?? 0, 0, "\(generation) 的思考块全都没有时长")
        }
        print("[transcript] 有时长的思考块: \(timed.sorted { $0.key < $1.key })")
    }

    // MARK: - 压缩

    /// 夹具里的压缩检查点要变成 `.compaction` 标记，而且检查点之前的历史
    /// 要还在正文里（replace 不删对话记录）。
    func testCompactionMarkerKeepsHistoryBeforeIt() throws {
        var markers = 0
        for r in try all() {
            for (i, node) in r.output.nodes.enumerated() {
                guard case .compaction = node else { continue }
                markers += 1
                XCTAssertGreaterThan(i, 0, "\(r.file): 压缩标记前面没有任何历史")
            }
        }
        print("[transcript] 压缩标记 \(markers) 个")
    }

    // MARK: - 汇总

    /// 打印每份夹具的节点构成，便于人工核对。
    func testPrintsNodeBreakdown() throws {
        for r in try all() {
            var counts: [String: Int] = [:]
            for node in r.output.nodes { counts[Self.kind(node), default: 0] += 1 }
            let line = counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            print("[transcript] \(r.file) 事件 \(r.events.count) → 节点 \(r.output.nodes.count): \(line)")
        }
    }

    private static func kind(_ node: ChatNode) -> String {
        switch node {
        case .user: return "user"
        case .reasoning: return "reasoning"
        case .tool: return "tool"
        case .assistant: return "assistant"
        case .turnTail: return "turnTail"
        case .inbox: return "inbox"
        case .compaction: return "compaction"
        case .retry: return "retry"
        case .command: return "command"
        case .todo: return "todo"
        case .deliverables: return "deliverables"
        case .unknown: return "unknown"
        }
    }

    // MARK: - App 内样例

    /// App 包里打的样例会话必须和夹具是同一份。两份副本一旦漂移，
    /// 真机上验收的就不是测试里验证过的那份数据了。
    /// 重新导出夹具后要同步：`cp Tests/Fixtures/v4-01.json App/Resources/sample-session.json`
    func testAppSampleMatchesFixture() throws {
        let root = Self.fixturesDir.deletingLastPathComponent().deletingLastPathComponent()
        let app = try Data(contentsOf: root.appendingPathComponent("App/Resources/sample-session.json"))
        let fixture = try Data(contentsOf: Self.fixturesDir.appendingPathComponent("v4-01.json"))
        XCTAssertEqual(app, fixture, "App/Resources/sample-session.json 与 Tests/Fixtures/v4-01.json 不一致")
    }
}
