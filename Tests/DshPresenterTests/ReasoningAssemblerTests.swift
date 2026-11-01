import XCTest
@testable import DshPresenter
@testable import DshSession

/// 思考块的装配与收起态摘要。
///
/// 这是装配器里最该先做对的一块：44.3% 的事件走这条路径。
final class ReasoningAssemblerTests: XCTestCase {

    private let assembler = ReasoningAssembler()

    /// 真实样本（旧代会话的两条连续思考 run）。
    private let runA = ChunkRun(
        index: 0,
        time0: 1_786_689_921_634,
        dt: [0, 2, 1, 0, 0, 0],
        texts: [" over", "rides", ".", " But", " the", " sub", "agent"]
    )
    private let runB = ChunkRun(
        index: 0,
        time0: 1_786_689_921_700,
        dt: [1, 0, 0, 1, 0, 0],
        texts: [" sub", "agents", ",", " but", " I", "'m", " not"]
    )

    /// 同一个块的多条 run 要累加，不是替换。
    func testMultipleRunsConcatenate() {
        let node = assembler.assemble(seq: 10, runs: [runA, runB], isStreaming: false)
        XCTAssertEqual(node.text, " overrides. But the subagent subagents, but I'm not")
    }

    /// 字数用字素簇计数。中文一个字算一个，不是 UTF-16 的长度。
    func testCharacterCountUsesGraphemes() {
        let run = ChunkRun(index: 0, time0: 0, dt: [], texts: ["你好世界"])
        let node = assembler.assemble(seq: 1, runs: [run], isStreaming: false)
        XCTAssertEqual(node.characterCount, 4)
    }

    /// emoji 和组合字符也按"用户看到几个"算。
    func testCharacterCountHandlesCombiningMarks() {
        // 家庭 emoji 是多个 code point 组成的一个字素簇
        let run = ChunkRun(index: 0, time0: 0, dt: [], texts: ["👨‍👩‍👧‍👦"])
        let node = assembler.assemble(seq: 1, runs: [run], isStreaming: false)
        XCTAssertEqual(node.characterCount, 1)
    }

    /// 单条 run 的耗时就是它自己 dt 的和。
    func testDurationOfSingleRun() {
        let node = assembler.assemble(seq: 1, runs: [runA], isStreaming: false)
        XCTAssertEqual(node.duration, 0.003, accuracy: 0.0001)
    }

    /// 跨 run 的空档必须算进思考时间。
    ///
    /// runA 结束于 time0+3 = ...637，runB 开始于 ...700，中间有 63 ms 的真实等待。
    /// 不算进去就会低估耗时——用户看到"思考 0.005 秒"而实际过了 0.07 秒。
    func testDurationIncludesGapsBetweenRuns() {
        let node = assembler.assemble(seq: 1, runs: [runA, runB], isStreaming: false)
        // runA 内部 3ms + 空档 63ms + runB 内部 2ms
        XCTAssertEqual(node.duration, 0.068, accuracy: 0.0001)
    }

    /// run 乱序到达时不能把时间算成负的。
    func testOutOfOrderRunsDoNotSubtractTime() {
        let later = ChunkRun(index: 0, time0: 2000, dt: [5], texts: ["a", "b"])
        let earlier = ChunkRun(index: 0, time0: 1000, dt: [5], texts: ["c", "d"])
        let node = assembler.assemble(seq: 1, runs: [later, earlier], isStreaming: false)
        // 两条 run 各 5ms，空档为负 → 按 0 处理
        XCTAssertEqual(node.duration, 0.010, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(node.duration, 0)
    }

    // MARK: - 收起态摘要

    func testStreamingSummaryOmitsDuration() {
        let node = ReasoningNode(
            seq: 1, text: "", characterCount: 320, duration: 1.5, isStreaming: true
        )
        XCTAssertEqual(assembler.collapsedSummary(node), "思考中 · 320 字")
    }

    func testCompletedSummaryShowsDurationAndCount() {
        let node = ReasoningNode(
            seq: 1, text: "", characterCount: 3400, duration: 12.44, isStreaming: false
        )
        XCTAssertEqual(assembler.collapsedSummary(node), "思考 12.4 秒 · 3.4k 字")
    }

    /// 上千用 k 缩写，否则收起那一行会被数字撑长。
    func testCountFormatting() {
        XCTAssertEqual(ReasoningAssembler.formatCount(0), "0")
        XCTAssertEqual(ReasoningAssembler.formatCount(999), "999")
        XCTAssertEqual(ReasoningAssembler.formatCount(1000), "1.0k")
        XCTAssertEqual(ReasoningAssembler.formatCount(3400), "3.4k")
        XCTAssertEqual(ReasoningAssembler.formatCount(9949), "9.9k")
        // 10k 以上不要小数位
        XCTAssertEqual(ReasoningAssembler.formatCount(12_400), "12k")
    }

    func testDurationFormatting() {
        XCTAssertEqual(ReasoningAssembler.formatDuration(0.5), "0.5 秒")
        XCTAssertEqual(ReasoningAssembler.formatDuration(12.44), "12.4 秒")
        XCTAssertEqual(ReasoningAssembler.formatDuration(59.9), "59.9 秒")
        XCTAssertEqual(ReasoningAssembler.formatDuration(60), "1 分")
        XCTAssertEqual(ReasoningAssembler.formatDuration(95), "1 分 35 秒")
    }

    /// 耗时几乎为 0 时不显示"思考 0.0 秒"，那读起来像出错了。
    func testNearZeroDurationOmitsTime() {
        let node = ReasoningNode(
            seq: 1, text: "", characterCount: 12, duration: 0.02, isStreaming: false
        )
        XCTAssertEqual(assembler.collapsedSummary(node), "思考 · 12 字")
    }

    func testEmptyRunsProduceEmptyNode() {
        let node = assembler.assemble(seq: 5, runs: [], isStreaming: false)
        XCTAssertEqual(node.text, "")
        XCTAssertEqual(node.characterCount, 0)
        XCTAssertEqual(node.duration, 0)
        XCTAssertEqual(node.seq, 5)
    }
}
