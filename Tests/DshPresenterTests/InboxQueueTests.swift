import XCTest
@testable import DshPresenter
@testable import DshSession

/// 排队输入的 splice 重放。
///
/// 这里最大的陷阱是把 `agent/inbox/spliced` 当成"追加一条消息"。它是数组 splice，
/// 带 `start` + `removedCount` + `inserted`。当成追加的话出队操作被忽略，
/// 队列只增不减，界面上堆积早已被消费的待发消息——不报错。
final class InboxQueueTests: XCTestCase {

    private let filter = UserMessageFilter()

    private func entry(_ text: String, id: String? = nil, source: String? = "user") -> InboxQueue.Entry {
        InboxQueue.Entry(id: id, sourceKind: source, text: text)
    }

    // MARK: - splice 语义

    func testInsertIntoEmptyQueue() {
        var queue = InboxQueue()
        queue.splice(target: .nextTurn, start: 0, removedCount: 0, inserted: [entry("第一条")])
        XCTAssertEqual(queue.nextTurn.map(\.text), ["第一条"])
    }

    /// 实测样本里最常见的一对操作：先插一条，再删掉它（入队然后被消费）。
    func testInsertThenRemoveLeavesQueueEmpty() {
        var queue = InboxQueue()
        queue.splice(target: .nextTurn, start: 0, removedCount: 0, inserted: [entry("待发")])
        queue.splice(target: .nextTurn, start: 0, removedCount: 1, inserted: [])
        XCTAssertTrue(queue.nextTurn.isEmpty, "出队操作必须真的删掉条目")
    }

    func testRemoveFromMiddle() {
        var queue = InboxQueue()
        queue.splice(
            target: .nextTurn, start: 0, removedCount: 0,
            inserted: [entry("a"), entry("b"), entry("c")]
        )
        queue.splice(target: .nextTurn, start: 1, removedCount: 1, inserted: [])
        XCTAssertEqual(queue.nextTurn.map(\.text), ["a", "c"])
    }

    /// 一次 splice 可以同时删和插（改写队列中的某条）。
    func testReplaceInPlace() {
        var queue = InboxQueue()
        queue.splice(
            target: .nextTurn, start: 0, removedCount: 0,
            inserted: [entry("旧"), entry("保留")]
        )
        queue.splice(target: .nextTurn, start: 0, removedCount: 1, inserted: [entry("新")])
        XCTAssertEqual(queue.nextTurn.map(\.text), ["新", "保留"])
    }

    func testInsertInMiddle() {
        var queue = InboxQueue()
        queue.splice(
            target: .nextTurn, start: 0, removedCount: 0,
            inserted: [entry("a"), entry("c")]
        )
        queue.splice(target: .nextTurn, start: 1, removedCount: 0, inserted: [entry("b")])
        XCTAssertEqual(queue.nextTurn.map(\.text), ["a", "b", "c"])
    }

    /// 实测约半数事件不带 `removedCount`（4,585 条里只有 2,191 条有），缺失按 0。
    func testMissingRemovedCountMeansZero() {
        var queue = InboxQueue()
        queue.splice(target: .nextTurn, start: 0, removedCount: 0, inserted: [entry("a")])
        queue.splice(target: .nextTurn, start: 1, removedCount: 0, inserted: [entry("b")])
        XCTAssertEqual(queue.nextTurn.count, 2)
    }

    // MARK: - 两条队列独立

    /// `next-step` 和 `next-turn` 是两条独立队列（实测各 2,312 / 2,273 次）。
    func testTargetsAreIndependent() {
        var queue = InboxQueue()
        queue.splice(target: .nextStep, start: 0, removedCount: 0, inserted: [entry("步")])
        queue.splice(target: .nextTurn, start: 0, removedCount: 0, inserted: [entry("轮")])

        XCTAssertEqual(queue.nextStep.map(\.text), ["步"])
        XCTAssertEqual(queue.nextTurn.map(\.text), ["轮"])
    }

    func testTargetParsing() {
        XCTAssertEqual(InboxQueue.Target(raw: "next-step"), .nextStep)
        XCTAssertEqual(InboxQueue.Target(raw: "next-turn"), .nextTurn)
        XCTAssertEqual(InboxQueue.Target(raw: "future-target"), .unknown("future-target"))
    }

    /// 不认识的 target 要忽略，不能猜它该插进哪条队列。
    func testUnknownTargetIsIgnored() {
        var queue = InboxQueue()
        queue.splice(
            target: .unknown("whatever"), start: 0, removedCount: 0, inserted: [entry("x")]
        )
        XCTAssertTrue(queue.nextStep.isEmpty)
        XCTAssertTrue(queue.nextTurn.isEmpty)
    }

    // MARK: - 越界

    /// 乱序到达或窗口从中间开始时，本地队列和 host 的不一致是正常的。
    /// 越界必须钳住——崩掉比少显示一条严重得多。
    func testStartBeyondEndClamps() {
        var queue = InboxQueue()
        queue.splice(target: .nextTurn, start: 0, removedCount: 0, inserted: [entry("a")])
        queue.splice(target: .nextTurn, start: 99, removedCount: 0, inserted: [entry("b")])
        XCTAssertEqual(queue.nextTurn.map(\.text), ["a", "b"])
    }

    func testNegativeStartClamps() {
        var queue = InboxQueue()
        queue.splice(target: .nextTurn, start: -5, removedCount: 0, inserted: [entry("a")])
        XCTAssertEqual(queue.nextTurn.map(\.text), ["a"])
    }

    func testRemoveCountBeyondEndClamps() {
        var queue = InboxQueue()
        queue.splice(target: .nextTurn, start: 0, removedCount: 0, inserted: [entry("a")])
        queue.splice(target: .nextTurn, start: 0, removedCount: 99, inserted: [])
        XCTAssertTrue(queue.nextTurn.isEmpty)
    }

    func testNegativeRemoveCountClamps() {
        var queue = InboxQueue()
        queue.splice(target: .nextTurn, start: 0, removedCount: 0, inserted: [entry("a")])
        queue.splice(target: .nextTurn, start: 0, removedCount: -3, inserted: [])
        XCTAssertEqual(queue.nextTurn.count, 1)
    }

    func testSpliceOnEmptyQueueWithRemoval() {
        var queue = InboxQueue()
        queue.splice(target: .nextTurn, start: 0, removedCount: 5, inserted: [])
        XCTAssertTrue(queue.nextTurn.isEmpty)
    }

    // MARK: - 队列条目也要过白名单

    /// 队列条目自带 `source.kind`，里面混着 agent 自己注入的东西。
    /// 不过滤的话，排队摘要会显示 runtime-context 之类的内部消息。
    func testInjectedEntriesAreHidden() {
        var queue = InboxQueue()
        queue.splice(
            target: .nextTurn, start: 0, removedCount: 0,
            inserted: [
                entry("真人的话", source: "user"),
                entry("内部注入", source: "runtime-context"),
            ]
        )
        XCTAssertEqual(queue.visibleEntries(queue.nextTurn, filter: filter).map(\.text), ["真人的话"])
        XCTAssertEqual(queue.visibleCount(filter: filter), 1)
    }

    /// 队列里只有注入时不产生节点——显示一个空的"排队中"会让用户困惑。
    func testAllInjectedProducesNoNode() {
        var queue = InboxQueue()
        queue.splice(
            target: .nextTurn, start: 0, removedCount: 0,
            inserted: [entry("注入", source: "agent-instructions")]
        )
        XCTAssertTrue(queue.nodes(seq: 1, filter: filter).isEmpty)
    }

    // MARK: - 节点与摘要

    func testSingleEntrySummary() {
        var queue = InboxQueue()
        queue.splice(
            target: .nextTurn, start: 0, removedCount: 0, inserted: [entry("帮我看看这个")]
        )
        let nodes = queue.nodes(seq: 7, filter: filter)
        XCTAssertEqual(nodes.count, 1)
        XCTAssertEqual(nodes[0].kind, .nextTurn)
        XCTAssertEqual(nodes[0].summary, "下一轮：帮我看看这个")
        XCTAssertEqual(nodes[0].seq, 7)
    }

    func testMultipleEntriesSummaryShowsCount() {
        var queue = InboxQueue()
        queue.splice(
            target: .nextStep, start: 0, removedCount: 0,
            inserted: [entry("第一条"), entry("第二条"), entry("第三条")]
        )
        let nodes = queue.nodes(seq: 1, filter: filter)
        XCTAssertEqual(nodes[0].kind, .nextStep)
        XCTAssertEqual(nodes[0].summary, "下一步：第一条 等 3 条")
    }

    /// 两条队列都有内容时产生两个节点，next-step 在前（它更早被消费）。
    func testBothQueuesProduceTwoNodes() {
        var queue = InboxQueue()
        queue.splice(target: .nextStep, start: 0, removedCount: 0, inserted: [entry("步")])
        queue.splice(target: .nextTurn, start: 0, removedCount: 0, inserted: [entry("轮")])

        let nodes = queue.nodes(seq: 1, filter: filter)
        XCTAssertEqual(nodes.map(\.kind), [.nextStep, .nextTurn])
    }

    func testEmptyQueueProducesNoNodes() {
        let queue = InboxQueue()
        XCTAssertTrue(queue.nodes(seq: 1, filter: filter).isEmpty)
        XCTAssertEqual(queue.visibleCount(filter: filter), 0)
    }

    /// 长文本在摘要里截断，而且按字素簇。
    func testLongTextTruncatedInSummary() {
        var queue = InboxQueue()
        queue.splice(
            target: .nextTurn, start: 0, removedCount: 0,
            inserted: [entry(String(repeating: "字", count: 200))]
        )
        let summary = queue.nodes(seq: 1, filter: filter)[0].summary
        XCTAssertTrue(summary.hasSuffix("…"))
        XCTAssertLessThan(summary.count, 80)
    }
}
