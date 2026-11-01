import XCTest
@testable import DshSession

/// 窗口的顺序与重写语义。
///
/// 这些规则的共同点是**出错时不报错**，只是显示重复或陈旧内容，所以全部要有测试。
final class SessionWindowTests: XCTestCase {

    private func rec(_ seq: EventSeq, _ type: String = "assistant/message", live: Bool = false) -> WindowedRecord {
        WindowedRecord(seq: seq, type: type, isLive: live)
    }

    func testUpsertKeepsSeqOrder() {
        var window = SessionWindow()
        window.upsert(rec(3))
        window.upsert(rec(1))
        window.upsert(rec(2))
        XCTAssertEqual(window.records.map(\.seq), [1, 2, 3])
    }

    func testUpsertReplacesSameSeq() {
        var window = SessionWindow()
        window.upsert(rec(1, "tool/call"))
        window.upsert(rec(1, "tool/result"))
        XCTAssertEqual(window.records.count, 1)
        XCTAssertEqual(window.records[0].type, "tool/result")
    }

    /// `surfaceOp.replace` 遮蔽的是**模型上下文**，不是对话记录。
    ///
    /// 窗口必须把被遮蔽的记录原样留着。早期实现"先删区间再插入"，回放真实会话
    /// 时一次压缩就抹掉了 1,298 个 seq 的历史——用户看过的内容从界面上消失。
    func testShadowedDoesNotRemoveRecords() {
        let window = SessionWindow(records: [rec(1), rec(2), rec(3), rec(4), rec(5)])
        let shadowed = window.shadowed(startSeq: 2, endSeq: 4)

        XCTAssertEqual(shadowed, [2, 3, 4])
        XCTAssertEqual(window.records.map(\.seq), [1, 2, 3, 4, 5], "遮蔽不能删掉对话记录")
    }

    /// 遮蔽区间是闭区间，两个端点都算。
    func testShadowedRangeIsInclusive() {
        let window = SessionWindow(records: [rec(1), rec(2), rec(3)])
        XCTAssertEqual(window.shadowed(startSeq: 1, endSeq: 3), [1, 2, 3])
    }

    /// 区间里没有记录（比如端点落在分页之外）时返回空，不出错。
    func testShadowedOutsideWindowIsEmpty() {
        let window = SessionWindow(records: [rec(10), rec(11)])
        XCTAssertEqual(window.shadowed(startSeq: 1, endSeq: 5), [])
    }

    /// 实测最宽的检查点替换跨 1,298 个 seq。窗口整段都要保留。
    func testWideCheckpointRangeKeepsAllHistory() {
        let records = (0..<1400).map { rec(EventSeq($0)) }
        let window = SessionWindow(records: records)

        XCTAssertEqual(window.shadowed(startSeq: 10, endSeq: 1307).count, 1298)
        XCTAssertEqual(window.records.count, 1400)
    }

    /// live chunk 的小数 seq 必须排在对应的两个耐久事件之间。
    ///
    /// host 算法：`durableCursor + 1 - 1/(n+1)`。durableCursor=5 时，
    /// 第 1 个 live chunk 是 5.5、第 2 个 5.667、第 3 个 5.75……越来越靠近 6。
    func testLiveChunksSortBetweenDurableEvents() {
        var window = SessionWindow()
        window.upsert(rec(5))
        window.upsert(rec(6))
        window.upsert(rec(5.5, "assistant/live-chunk", live: true))
        window.upsert(rec(5 + 2.0 / 3.0, "assistant/live-chunk", live: true))

        XCTAssertEqual(window.records.map(\.seq), [5, 5.5, 5 + 2.0 / 3.0, 6])
    }

    /// 耐久事件到达后，同位置的 live chunk 要退役，否则内容显示两遍。
    func testRetireLiveChunksWhenDurableArrives() {
        var window = SessionWindow()
        window.upsert(rec(5))
        window.upsert(rec(5.5, "assistant/live-chunk", live: true))
        window.upsert(rec(5.75, "assistant/live-chunk", live: true))

        window.retireLiveChunks(upTo: 6)
        window.upsert(rec(6))

        XCTAssertEqual(window.records.map(\.seq), [5, 6])
        XCTAssertTrue(window.records.allSatisfy { !$0.isLive })
    }

    /// 退役只清当前区间，不能误删更早的 live chunk。
    func testRetireDoesNotTouchEarlierLiveChunks() {
        var window = SessionWindow()
        window.upsert(rec(1))
        window.upsert(rec(1.5, "assistant/live-chunk", live: true))
        window.upsert(rec(5))
        window.upsert(rec(5.5, "assistant/live-chunk", live: true))

        window.retireLiveChunks(upTo: 6)

        // 1.5 不在 (5,6) 区间里，必须保留
        XCTAssertEqual(window.records.map(\.seq), [1, 1.5, 5])
    }

    func testDurableCursorIgnoresLiveChunks() {
        var window = SessionWindow()
        window.upsert(rec(5))
        window.upsert(rec(5.9, "assistant/live-chunk", live: true))
        XCTAssertEqual(window.durableCursor, 5)
    }

    func testDurableCursorOnEmptyWindow() {
        XCTAssertNil(SessionWindow().durableCursor)
    }
}
