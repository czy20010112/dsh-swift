import XCTest
@testable import DshPresenter
@testable import DshSession

/// 工具节点的装配、分级与摘要。
///
/// 夹具里的工具名、字段名和体积都取自实测分布，不是编的。
final class ToolAssemblerTests: XCTestCase {

    private let assembler = ToolAssembler()

    private func call(
        _ name: String,
        arguments: String,
        seq: EventSeq = 1,
        callId: String = "c1"
    ) -> ToolAssembler.Call {
        ToolAssembler.Call(seq: seq, callId: callId, name: name, arguments: arguments)
    }

    // MARK: - 配对

    /// 按 callId 配对，不靠顺序。工具可以并发，结果到达顺序和调用顺序无关。
    func testPairsByCallIdNotOrder() {
        let calls = [
            call("read", arguments: #"{"file_path":"/a"}"#, seq: 1, callId: "x"),
            call("read", arguments: #"{"file_path":"/b"}"#, seq: 2, callId: "y"),
        ]
        // 结果按相反顺序给
        let results = [
            "y": ToolAssembler.Result(callId: "y", text: "B 的内容", isError: false),
            "x": ToolAssembler.Result(callId: "x", text: "A 的内容", isError: false),
        ]
        let nodes = assembler.assemble(calls: calls, results: results)
        XCTAssertEqual(nodes[0].resultText, "A 的内容")
        XCTAssertEqual(nodes[1].resultText, "B 的内容")
    }

    /// 结果还没到的调用要能渲染（流式中就是这个状态）。
    func testCallWithoutResultStillProducesNode() {
        let nodes = assembler.assemble(
            calls: [call("pwsh", arguments: #"{"command":"ls"}"#)],
            results: [:]
        )
        XCTAssertEqual(nodes.count, 1)
        XCTAssertNil(nodes[0].resultText)
        XCTAssertFalse(nodes[0].isError)
    }

    func testErrorFlagCarriesThrough() {
        let nodes = assembler.assemble(
            calls: [call("pwsh", arguments: #"{"command":"false"}"#)],
            results: ["c1": .init(callId: "c1", text: "exit 1", isError: true)]
        )
        XCTAssertTrue(nodes[0].isError)
    }

    // MARK: - 分级

    /// 覆盖 88.1% 调用的那 5 个工具走专用卡。
    func testTopToolsGetSpecializedCard() {
        for name in ["pwsh", "read", "edit", "write", "grep", "glob"] {
            let node = assembler.assemble(
                calls: [call(name, arguments: #"{"file_path":"/x"}"#)],
                results: [:]
            )[0]
            XCTAssertEqual(node.tier, .specialized, "\(name) 应该走专用卡")
        }
    }

    /// 长尾的 55 种工具（含全部 MCP 与 dev_* 工具）走通用卡，不能崩。
    func testLongTailGetsGenericCard() {
        for name in ["mcp__rea__binary_session", "dev_stage_call", "web_fetch", "todo_write"] {
            let node = assembler.assemble(
                calls: [call(name, arguments: #"{"whatever":1}"#)],
                results: [:]
            )[0]
            XCTAssertEqual(node.tier, .generic, "\(name) 应该走通用卡")
        }
    }

    /// 参数解不开就兜底。现实原因是流式中途读到残缺的 JSON 前缀，
    /// 不是上游发了坏数据（实测 47,955 次调用零个非法 JSON）。
    func testUnparsableArgumentsFallBackToRaw() {
        let node = assembler.assemble(
            calls: [call("pwsh", arguments: #"{"command":"ls","#)],
            results: [:]
        )[0]
        XCTAssertEqual(node.tier, .raw)
    }

    func testEmptyArgumentsFallBackToRaw() {
        let node = assembler.assemble(calls: [call("pwsh", arguments: "")], results: [:])[0]
        XCTAssertEqual(node.tier, .raw)
    }

    /// arguments 是数组或字符串而不是对象时也走兜底。
    func testNonObjectArgumentsFallBackToRaw() {
        let node = assembler.assemble(
            calls: [call("pwsh", arguments: "[1,2,3]")],
            results: [:]
        )[0]
        XCTAssertEqual(node.tier, .raw)
    }

    // MARK: - 参数摘要

    /// `description` 优先于 `command`：两者在 pwsh 上几乎总是成对出现
    /// （26,163 对 25,850 次），而 description 是人话。
    func testDescriptionWinsOverCommand() {
        let summary = assembler.argumentSummary(
            for: call("pwsh", arguments: #"{"command":"git status --porcelain","description":"查看工作区状态"}"#)
        )
        XCTAssertEqual(summary, "查看工作区状态")
    }

    func testCommandUsedWhenNoDescription() {
        let summary = assembler.argumentSummary(
            for: call("pwsh", arguments: #"{"command":"git status"}"#)
        )
        XCTAssertEqual(summary, "git status")
    }

    func testFilePathForReadTools() {
        let summary = assembler.argumentSummary(
            for: call("read", arguments: #"{"file_path":"/workspace/main.swift","limit":100}"#)
        )
        XCTAssertEqual(summary, "/workspace/main.swift")
    }

    func testPatternForGrep() {
        let summary = assembler.argumentSummary(
            for: call("grep", arguments: #"{"pattern":"func assemble","path":"/workspace"}"#)
        )
        XCTAssertEqual(summary, "func assemble")
    }

    /// 长尾工具的自定义参数没命中优先级表时，列字段名——
    /// 至少让用户知道这次调用带了什么，而不是显示空白。
    func testUnknownFieldsListKeyNames() {
        let summary = assembler.argumentSummary(
            for: call("custom_tool", arguments: #"{"zeta":1,"alpha":2}"#)
        )
        XCTAssertEqual(summary, "alpha, zeta")
    }

    func testEmptyObjectProducesEmptySummary() {
        XCTAssertEqual(assembler.argumentSummary(for: call("noop", arguments: "{}")), "")
    }

    /// 摘要是一行，换行要压成空格。保留换行会让这一行看起来是空的。
    func testNewlinesFlattenedInSummary() {
        let summary = assembler.argumentSummary(
            for: call("pwsh", arguments: #"{"command":"line1\nline2\nline3"}"#)
        )
        XCTAssertEqual(summary, "line1 line2 line3")
    }

    /// 按字素簇截断，不是 UTF-16 offset——否则截断点可能落在组合字符中间。
    func testTruncationCountsGraphemes() {
        let text = String(repeating: "家", count: 200)
        let summary = assembler.argumentSummary(
            for: call("pwsh", arguments: #"{"command":"\(text)"}"#),
            limit: 10
        )
        XCTAssertEqual(summary.count, 11, "10 个字素 + 省略号")
        XCTAssertTrue(summary.hasSuffix("…"))
    }

    func testEmojiNotSplitByTruncation() {
        let summary = ToolAssembler.truncate("👨‍👩‍👧‍👦👨‍👩‍👧‍👦👨‍👩‍👧‍👦", to: 2)
        XCTAssertEqual(summary.count, 3, "2 个字素簇 + 省略号")
    }

    /// 数组参数只报个数，展开才看内容。
    func testArrayArgumentsReportCount() {
        let summary = assembler.argumentSummary(
            for: call("todo_write", arguments: #"{"todos":[{"a":1},{"b":2},{"c":3}]}"#)
        )
        XCTAssertEqual(summary, "3 项")
    }

    /// 嵌套对象在一行里没有意义，应该跳到下一个候选字段。
    func testNestedObjectSkipsToNextField() {
        let summary = assembler.argumentSummary(
            for: call("x", arguments: #"{"description":{"nested":true},"command":"fallback"}"#)
        )
        XCTAssertEqual(summary, "fallback")
    }

    func testNumericArgumentStringified() {
        let summary = assembler.argumentSummary(
            for: call("job_output", arguments: #"{"job_id":12345}"#)
        )
        XCTAssertEqual(summary, "12345")
    }

    // MARK: - 结果摘要

    func testResultSummaryShowsFirstLineAndCount() {
        let node = assembler.assemble(
            calls: [call("pwsh", arguments: #"{"command":"ls"}"#)],
            results: ["c1": .init(callId: "c1", text: "a.txt\nb.txt\nc.txt", isError: false)]
        )[0]
        XCTAssertEqual(assembler.resultSummary(for: node), "a.txt · 3 行")
    }

    func testSingleLineResultOmitsCount() {
        let node = assembler.assemble(
            calls: [call("pwsh", arguments: #"{"command":"pwd"}"#)],
            results: ["c1": .init(callId: "c1", text: "/workspace", isError: false)]
        )[0]
        XCTAssertEqual(assembler.resultSummary(for: node), "/workspace")
    }

    /// 空输出要明说，不能显示空白——用户分不清"没输出"和"还没返回"。
    func testEmptyResultSaysSo() {
        let node = assembler.assemble(
            calls: [call("pwsh", arguments: #"{"command":"true"}"#)],
            results: ["c1": .init(callId: "c1", text: "", isError: false)]
        )[0]
        XCTAssertEqual(assembler.resultSummary(for: node), "无输出")
    }

    func testMissingResultHasNoSummary() {
        let node = assembler.assemble(
            calls: [call("pwsh", arguments: #"{"command":"sleep 10"}"#)],
            results: [:]
        )[0]
        XCTAssertNil(assembler.resultSummary(for: node))
    }

    // MARK: - 大结果

    /// 超过 8 KB 走"查看全文"。实测 p99 是 27,437 字符、max 128,705，
    /// 整段塞进 cell 会让列表为测一个高度去排版两万多字。
    func testLargeResultNeedsFullTextView() {
        let big = String(repeating: "x", count: ToolAssembler.inlineResultLimit + 1)
        let node = assembler.assemble(
            calls: [call("read", arguments: #"{"file_path":"/big"}"#)],
            results: ["c1": .init(callId: "c1", text: big, isError: false)]
        )[0]
        XCTAssertTrue(assembler.needsFullTextView(node))
    }

    func testSmallResultRendersInline() {
        let node = assembler.assemble(
            calls: [call("read", arguments: #"{"file_path":"/small"}"#)],
            results: ["c1": .init(callId: "c1", text: "短内容", isError: false)]
        )[0]
        XCTAssertFalse(assembler.needsFullTextView(node))
    }

    /// 正好在边界上不触发全文视图。
    func testResultAtLimitRendersInline() {
        let exact = String(repeating: "x", count: ToolAssembler.inlineResultLimit)
        let node = assembler.assemble(
            calls: [call("read", arguments: #"{"file_path":"/exact"}"#)],
            results: ["c1": .init(callId: "c1", text: exact, isError: false)]
        )[0]
        XCTAssertFalse(assembler.needsFullTextView(node))
    }
}
