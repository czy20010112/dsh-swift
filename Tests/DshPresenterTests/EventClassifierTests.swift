import XCTest
@testable import DshPresenter
@testable import DshSession

/// 事件分类。
///
/// 这一层的核心性质是"未知事件安全降级"——事件词表随插件漂移，
/// 三份样本分别数出 54 / 47 / 39 种，所以"没见过的事件"是常态而非异常。
final class EventClassifierTests: XCTestCase {

    // MARK: - 未知事件安全降级

    /// 这是整个分类器最重要的一条：**未知事件忽略，不报错、不崩**。
    ///
    /// 对未知事件报错会让整个会话打不开；漏显示一种低频事件只是可接受的降级。
    func testUnknownEventIsIgnorable() {
        XCTAssertEqual(EventClassifier.effect(of: "some/future-event"), .ignorable)
        XCTAssertFalse(EventClassifier.producesNode("some/future-event"))
    }

    /// 插件专属事件也走忽略。本机样本里就有
    /// `web/deepseek-search-llm-request`(497) 和 `team/message/queued`(332)。
    func testPluginEventsAreIgnorable() {
        XCTAssertEqual(EventClassifier.effect(of: "web/deepseek-search-llm-request"), .ignorable)
        XCTAssertEqual(EventClassifier.effect(of: "team/message/queued"), .ignorable)
        XCTAssertEqual(EventClassifier.effect(of: "tool-workflow/agent-start"), .ignorable)
    }

    func testEmptyTypeIsIgnorable() {
        XCTAssertEqual(EventClassifier.effect(of: ""), .ignorable)
    }

    // MARK: - 流分片

    /// 流分片不自己产生节点——由装配器累加后产生。
    /// 分错的话思考内容会既出现在分片节点里、又出现在装配后的节点里。
    func testStreamChunksDoNotProduceNodes() {
        for type in ["reasoning-chunks", "text-chunks", "tool-call-chunks", "assistant/chunk"] {
            XCTAssertTrue(EventClassifier.isStreamChunk(type), "\(type) 应该是流分片")
            XCTAssertFalse(EventClassifier.producesNode(type), "\(type) 不该自己产生节点")
        }
    }

    // MARK: - 结构边界

    /// 结构边界影响节点归属但自己不显示。
    func testStructuralEventsDoNotProduceNodes() {
        for type in ["turn/start", "turn/end", "step/start", "step/end", "assistant/attempt"] {
            XCTAssertEqual(EventClassifier.effect(of: type), .structure)
            XCTAssertFalse(EventClassifier.producesNode(type))
        }
    }

    // MARK: - 产生节点

    func testHighFrequencyEventsProduceNodes() {
        for type in ["tool/call", "tool/result", "assistant/message", "user/message", "agent/inbox/spliced"] {
            XCTAssertTrue(EventClassifier.producesNode(type), "\(type) 应该产生节点")
        }
    }

    /// 压缩全链都要显示——上下文被压缩是用户需要知道的事。
    func testCompactionChainProducesNodes() {
        for type in ["compaction/start", "compaction/end", "compaction/prune", "compaction/summary"] {
            XCTAssertTrue(EventClassifier.producesNode(type))
        }
    }

    /// 重试必须显示：重试期间界面上什么都不动，用户分不清是卡住还是在等。
    func testRetryProducesNode() {
        XCTAssertTrue(EventClassifier.producesNode("llm/retry"))
        XCTAssertTrue(EventClassifier.producesNode("llm/retry-started"))
    }

    // MARK: - 会话头与元信息

    /// 这几个只更新会话头的状态行，不进正文——否则正文里会插进一排
    /// "沙箱模式已变更"之类的噪音。实测它们各出现 340-350 次。
    func testPolicyEventsGoToHeaderNotTranscript() {
        for type in ["permission/preset", "approval/policy", "sandbox/mode", "model/selection"] {
            XCTAssertEqual(EventClassifier.effect(of: type), .headerStatus)
            XCTAssertFalse(EventClassifier.producesNode(type))
        }
    }

    func testTitleIsMetadata() {
        XCTAssertEqual(EventClassifier.effect(of: "session/title"), .metadata)
        XCTAssertFalse(EventClassifier.producesNode("session/title"))
    }

    // MARK: - 明确忽略的高频事件

    /// 这几个频次不低但确实没有正文后果，要显式标成忽略而不是靠默认——
    /// 显式标注才能和"真的没见过"区分开。
    func testExplicitlyIgnoredEvents() {
        for type in ["request/header", "workspace/changes", "request/context", "session"] {
            XCTAssertEqual(EventClassifier.effect(of: type), .ignorable)
        }
    }

    /// 已建模的种类数应该覆盖实测 54 种里有 UI 后果的那些。
    func testModeledCountCoversMeasuredTypes() {
        XCTAssertGreaterThanOrEqual(EventClassifier.modeledCount, 40)
    }

    // MARK: - 重试提示

    func testRetrySummaryUsesReadableCode() {
        let notice = RetryNotice(
            seq: 1285, code: "TRANSPORT", message: "Connection error.",
            attempt: 1, maxAttempts: 5
        )
        XCTAssertEqual(notice.summary, "重试 1/5 · 连接中断")
    }

    /// 实测出现的五种失败代码全部要有中文说法。
    func testAllMeasuredFailureCodesAreReadable() {
        let expected = [
            "TRANSPORT": "连接中断",
            "RATE_LIMIT": "触发限流",
            "TIMEOUT": "超时",
            "SERVER": "服务端错误",
            "EMPTY_RESPONSE": "空响应",
        ]
        for (code, text) in expected {
            XCTAssertEqual(RetryNotice.readableCode(code), text)
        }
    }

    /// 没见过的代码原样显示，不猜。
    func testUnknownCodePassesThrough() {
        XCTAssertEqual(RetryNotice.readableCode("WEIRD_NEW_CODE"), "WEIRD_NEW_CODE")
    }

    /// 没有代码时退回到 message。
    func testFallsBackToMessageWhenNoCode() {
        let notice = RetryNotice(
            seq: 1, code: nil, message: "something went wrong", attempt: 2, maxAttempts: 5
        )
        XCTAssertEqual(notice.summary, "重试 2/5 · something went wrong")
    }

    /// 两者都没有时也要有个说法，不能显示空白。
    func testFallsBackToUnknownReason() {
        let notice = RetryNotice(seq: 1, code: nil, message: nil, attempt: 3, maxAttempts: 5)
        XCTAssertEqual(notice.summary, "重试 3/5 · 未知原因")
    }

    func testEmptyCodeFallsBackToMessage() {
        let notice = RetryNotice(
            seq: 1, code: "", message: "fallback text", attempt: 1, maxAttempts: 3
        )
        XCTAssertEqual(notice.summary, "重试 1/3 · fallback text")
    }
}
