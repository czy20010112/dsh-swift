import XCTest
@testable import DshSession

/// 压缩流的展开。
///
/// 夹具取自真实会话，不是编的数字——因为 `dt` 与 `texts` 的长度关系是这套格式里
/// 最容易想错的地方，而想错了只会让时间戳偏移，不会报错。
final class AssistantStreamTests: XCTestCase {

    /// 真实样本之一（旧代会话的思考分片）。
    ///
    /// 注意 `dt` 有 6 个元素而 `texts` 有 7 个：第一个分片的时间就是 `time0`，
    /// 之后每个分片累加一个 dt。
    private let realRun = ChunkRun(
        index: 0,
        time0: 1_786_689_921_634,
        dt: [0, 2, 1, 0, 0, 0],
        texts: [" over", "rides", ".", " But", " the", " sub", "agent"]
    )

    func testRealSampleHasOneFewerDeltaThanTexts() {
        XCTAssertEqual(realRun.dt.count, realRun.texts.count - 1)
    }

    func testExpandProducesOneChunkPerText() {
        let expanded = AssistantStream.expand(realRun)
        XCTAssertEqual(expanded.count, realRun.texts.count)
        XCTAssertEqual(expanded.map(\.text), realRun.texts)
    }

    /// 第一个分片的时间必须正好是 `time0`，不能提前累加 dt[0]。
    func testFirstChunkKeepsTime0() {
        let expanded = AssistantStream.expand(realRun)
        XCTAssertEqual(expanded.first?.time, 1_786_689_921_634)
    }

    /// 时间按 dt 逐个累加。dt = [0,2,1,0,0,0] 的累计偏移应为 0,0,2,3,3,3,3。
    func testTimesAccumulateDeltas() {
        let expanded = AssistantStream.expand(realRun)
        let offsets = expanded.map { $0.time - realRun.time0 }
        XCTAssertEqual(offsets, [0, 0, 2, 3, 3, 3, 3])
    }

    /// 最后一个分片的时间 = time0 + dt 全部之和。
    func testLastChunkTimeMatchesTotalDuration() {
        let expanded = AssistantStream.expand(realRun)
        let total = Int64(realRun.dt.reduce(0, +))
        XCTAssertEqual(expanded.last?.time, realRun.time0 + total)
    }

    /// 块内容是分片**拼接**，不是替换。
    func testJoinedTextConcatenates() {
        XCTAssertEqual(
            AssistantStream.joinedText(realRun),
            " overrides. But the subagent"
        )
    }

    func testDurationSumsDeltas() {
        XCTAssertEqual(AssistantStream.duration(realRun), 3)
    }

    /// 每个分片都带所属块的 index，展开后不能丢。
    func testExpandedChunksCarryBlockIndex() {
        let run = ChunkRun(index: 7, time0: 1000, dt: [5], texts: ["a", "b"])
        XCTAssertEqual(AssistantStream.expand(run).map(\.index), [7, 7])
    }

    // MARK: - 退化输入

    func testSingleTextNeedsNoDeltas() {
        let run = ChunkRun(index: 0, time0: 500, dt: [], texts: ["只有一片"])
        let expanded = AssistantStream.expand(run)
        XCTAssertEqual(expanded.count, 1)
        XCTAssertEqual(expanded[0].time, 500)
        XCTAssertEqual(AssistantStream.duration(run), 0)
    }

    func testEmptyRunExpandsToNothing() {
        let run = ChunkRun(index: 0, time0: 500, dt: [], texts: [])
        XCTAssertTrue(AssistantStream.expand(run).isEmpty)
        XCTAssertEqual(AssistantStream.duration(run), 0)
    }

    /// 截断的历史里 dt 可能不够长。缺的按 0 补——宁可时间偏早，也不要丢内容。
    func testShortDeltaArrayDoesNotDropTexts() {
        let run = ChunkRun(index: 0, time0: 100, dt: [10], texts: ["a", "b", "c", "d"])
        let expanded = AssistantStream.expand(run)
        XCTAssertEqual(expanded.map(\.text), ["a", "b", "c", "d"])
        XCTAssertEqual(expanded.map(\.time), [100, 110, 110, 110])
    }

    /// dt 比需要的多（上游多塞了）时，duration 只算用得到的那部分。
    func testExtraDeltasAreIgnoredInDuration() {
        let run = ChunkRun(index: 0, time0: 0, dt: [1, 2, 99, 99], texts: ["a", "b", "c"])
        // 只有 texts.count - 1 = 2 个 dt 被用到
        XCTAssertEqual(AssistantStream.duration(run), 3)
        XCTAssertEqual(AssistantStream.expand(run).map(\.time), [0, 1, 3])
    }

    // MARK: - 负 dt

    /// 实测 v4 里有 9 个负 dt（最小 -1462 ms）。照算会让耗时偏小。
    func testNegativeDeltaDoesNotReduceDuration() {
        let run = ChunkRun(index: 0, time0: 0, dt: [100, -1462, 50], texts: ["a", "b", "c", "d"])
        XCTAssertEqual(AssistantStream.duration(run), 150)
    }

    /// 展开后的时间戳不能倒流，否则按时间排序的分片会乱序。
    func testNegativeDeltaKeepsTimestampsMonotonic() {
        let run = ChunkRun(index: 0, time0: 1000, dt: [100, -1462, 50], texts: ["a", "b", "c", "d"])
        let times = AssistantStream.expand(run).map(\.time)
        XCTAssertEqual(times, [1000, 1100, 1100, 1150])
        XCTAssertEqual(times, times.sorted())
    }
}
