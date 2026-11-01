import XCTest
@testable import DshPresenter
@testable import DshSession

/// 用户行白名单。
///
/// 这道闸门失效的症状是"用户气泡刷屏"——正文里混进成百上千条 agent 自己注入的
/// 消息，看起来像用户在疯狂发言。实测样本里会多出 2,466 条。
final class UserMessageFilterTests: XCTestCase {

    private let filter = UserMessageFilter()

    // MARK: - 白名单

    func testRealUserRenders() {
        XCTAssertTrue(filter.shouldRender(sourceKind: "user"))
    }

    /// 只占 0.1%（3 次），但不渲染会让对话出现"问了没人答"的断裂。
    func testQuestionReplyRenders() {
        XCTAssertTrue(filter.shouldRender(sourceKind: "user-question-reply"))
    }

    /// 实测到的 18 种注入来源，一个都不能渲染。
    func testAllMeasuredInjectionSourcesAreHidden() {
        let injected = [
            "skill-catalog", "subagent-settled", "tool-jobs", "team-message",
            "agent-instructions", "runtime-context", "agent-message", "plugin",
            "ds-bot-time-context", "model-selection", "compact-checkpoint", "goal",
            "subagent-report", "user-approval", "time-context", "tool-goal",
            "bot", "repeat-tool-reminder",
        ]
        for kind in injected {
            XCTAssertFalse(
                filter.shouldRender(sourceKind: kind),
                "\(kind) 是注入，不该渲染成用户发言"
            )
        }
    }

    /// 白名单的关键性质：**没见过的来源默认隐藏**。
    ///
    /// 上游每加一种注入来源，黑名单就漏一批；白名单不会。
    func testUnknownSourceIsHiddenByDefault() {
        XCTAssertFalse(filter.shouldRender(sourceKind: "some-future-injection"))
    }

    func testMissingSourceIsHidden() {
        XCTAssertFalse(filter.shouldRender(sourceKind: nil))
    }

    /// `user-approval` 名字里带 user，但它是注入——这正是黑名单容易看走眼的地方。
    func testUserApprovalIsNotAUserMessage() {
        XCTAssertFalse(filter.shouldRender(sourceKind: "user-approval"))
    }

    // MARK: - 节点装配

    func testUserNodeCarriesJoinedText() {
        let node = filter.node(seq: 8, sourceKind: "user", texts: ["请", "帮我", "看看"])
        XCTAssertEqual(node?.text, "请帮我看看")
        XCTAssertEqual(node?.seq, 8)
    }

    func testInjectionProducesNoNode() {
        XCTAssertNil(filter.node(seq: 8, sourceKind: "runtime-context", texts: ["..."]))
    }

    // MARK: - 提问答复的 JSON 载荷

    /// `user-question-reply` 的 text 是 JSON，不是人话。
    /// 原样渲染的话用户会看到一坨带转义的 JSON。
    func testQuestionReplyExtractsCustomAnswer() {
        let payload = """
        {"kind":"answer_to_pending_question","tool":"ask_user",\
        "questions":[{"id":"q1","question":"先做哪块？"}],\
        "answers":[{"id":"q1","selected":[],"custom":"先做本地部署"}]}
        """
        let node = filter.node(seq: 26, sourceKind: "user-question-reply", texts: [payload])
        XCTAssertEqual(node?.text, "先做本地部署")
    }

    func testQuestionReplyExtractsSelectedLabels() {
        let payload = """
        {"answers":[{"id":"q1","selected":["DSH 插件开发","Web 逆向"],"custom":""}]}
        """
        let node = filter.node(seq: 26, sourceKind: "user-question-reply", texts: [payload])
        XCTAssertEqual(node?.text, "DSH 插件开发、Web 逆向")
    }

    /// 选项和自定义输入都有时，两者都要显示。
    func testQuestionReplyCombinesSelectedAndCustom() {
        let payload = """
        {"answers":[{"id":"q1","selected":["选项甲"],"custom":"另外补充一句"}]}
        """
        let node = filter.node(seq: 26, sourceKind: "user-question-reply", texts: [payload])
        XCTAssertEqual(node?.text, "选项甲、另外补充一句")
    }

    /// 选中项可能是对象而不是字符串，取它的 label。
    func testSelectedObjectsUseLabel() {
        let payload = """
        {"answers":[{"id":"q1","selected":[{"label":"甲","description":"x"}],"custom":""}]}
        """
        let node = filter.node(seq: 26, sourceKind: "user-question-reply", texts: [payload])
        XCTAssertEqual(node?.text, "甲")
    }

    /// 多个问题的答复用换行分隔。
    func testMultipleAnswersJoinWithNewline() {
        let payload = """
        {"answers":[{"id":"q1","selected":["甲"],"custom":""},\
        {"id":"q2","selected":[],"custom":"乙"}]}
        """
        let node = filter.node(seq: 26, sourceKind: "user-question-reply", texts: [payload])
        XCTAssertEqual(node?.text, "甲\n乙")
    }

    /// 解析不了就原样显示——有总比没有好，而且能暴露格式变化。
    func testUnparsablePayloadFallsBackToRaw() {
        let node = filter.node(seq: 26, sourceKind: "user-question-reply", texts: ["不是 JSON"])
        XCTAssertEqual(node?.text, "不是 JSON")
    }

    /// 载荷是合法 JSON 但没有 answers 字段时也回退，不能显示空白。
    func testPayloadWithoutAnswersFallsBackToRaw() {
        let payload = #"{"kind":"answer_to_pending_question"}"#
        let node = filter.node(seq: 26, sourceKind: "user-question-reply", texts: [payload])
        XCTAssertEqual(node?.text, payload)
    }

    /// 全空的答复（用户什么都没选也没填）回退到原文，
    /// 否则正文里会出现一个空气泡。
    func testEmptyAnswersFallBackToRaw() {
        let payload = #"{"answers":[{"id":"q1","selected":[],"custom":""}]}"#
        let node = filter.node(seq: 26, sourceKind: "user-question-reply", texts: [payload])
        XCTAssertEqual(node?.text, payload)
    }

    /// 只有空白的 custom 不算回答。
    func testWhitespaceOnlyCustomIsIgnored() {
        let payload = #"{"answers":[{"id":"q1","selected":["甲"],"custom":"   \n  "}]}"#
        let node = filter.node(seq: 26, sourceKind: "user-question-reply", texts: [payload])
        XCTAssertEqual(node?.text, "甲")
    }

    // MARK: - 隐藏不等于丢弃

    /// 被隐藏的注入仍然要能在轨迹视图里看到——排查问题时需要知道 agent
    /// 到底被喂了什么。
    func testHiddenSourcesRemainTraceable() {
        XCTAssertTrue(filter.isTraceable(sourceKind: "runtime-context"))
        XCTAssertTrue(filter.isTraceable(sourceKind: "skill-catalog"))
    }
}
