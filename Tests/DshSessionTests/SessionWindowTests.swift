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

    /// `surfaceOp.replace` 的核心语义：先删区间，再插新记录。
    ///
    /// 如果实现成"先插后删"，新记录会被自己的删除区间吃掉（当它的 seq 落在区间内时），
    /// 或者留下旧记录造成重复。
    func testReplaceRemovesRangeThenInserts() {
        var window = SessionWindow(records: [
            rec(1), rec(2), rec(3), rec(4), rec(5),
        ])
        // 用一条 seq=2 的新记录替换 [2,4]
        window.replace(startSeq: 2, endSeq: 4, with: rec(2, "assistant/message-rewritten"))

        XCTAssertEqual(window.records.map(\.seq), [1, 2, 5])
        XCTAssertEqual(window.records[1].type, "assistant/message-rewritten")
    }

    /// 替换区间是**闭区间**，两个端点都要删掉。
    func testReplaceRangeIsInclusive() {
        var window = SessionWindow(records: [rec(1), rec(2), rec(3)])
        window.replace(startSeq: 1, endSeq: 3, with: rec(1, "replacement"))
        XCTAssertEqual(window.records.count, 1)
        XCTAssertEqual(window.records[0].type, "replacement")
    }

    /// 替换后不能留下重复 seq——这是"同一条回复出现两次"的直接原因。
    func testReplaceLeavesNoDuplicateSeq() {
        var window = SessionWindow(records: [rec(1), rec(2), rec(3)])
        window.replace(startSeq: 2, endSeq: 2, with: rec(2, "new"))
        let seqs = window.records.map(\.seq)
        XCTAssertEqual(seqs, Array(Set(seqs)).sorted(), "窗口里出现了重复 seq")
        XCTAssertEqual(seqs, [1, 2, 3])
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
