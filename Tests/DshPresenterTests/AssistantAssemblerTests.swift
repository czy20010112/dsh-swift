import XCTest
@testable import DshPresenter
@testable import DshSession

/// 助手正文的装配与流式安全渲染。
final class AssistantAssemblerTests: XCTestCase {

    private let assembler = AssistantAssembler()

    private func run(_ texts: [String], index: Int = 0) -> ChunkRun {
        ChunkRun(index: index, time0: 0, dt: Array(repeating: 1, count: max(0, texts.count - 1)), texts: texts)
    }

    // MARK: - 基本装配

    func testSingleBlockJoinsRuns() {
        let block = AssistantAssembler.Block(index: 0, runs: [run(["我先", "看一下"]), run(["文档。"])])
        let node = assembler.assemble(seq: 10, block: block, isStreaming: false)
        XCTAssertEqual(node.markdown, "我先看一下文档。")
        XCTAssertEqual(node.seq, 10)
        XCTAssertFalse(node.isStreaming)
    }

    /// 同一次回复里的多个文本块之间要有段落间隔，否则两段话黏在一起。
    func testMultipleBlocksSeparatedByBlankLine() {
        let blocks = [
            AssistantAssembler.Block(index: 0, runs: [run(["第一段"])]),
            AssistantAssembler.Block(index: 2, runs: [run(["第二段"])]),
        ]
        let node = assembler.assemble(seq: 1, blocks: blocks, isStreaming: false)
        XCTAssertEqual(node.markdown, "第一段\n\n第二段")
    }

    /// 块要按 index 排序，不按到达顺序——流式下它们可能交错。
    func testBlocksSortByIndex() {
        let blocks = [
            AssistantAssembler.Block(index: 5, runs: [run(["后"])]),
            AssistantAssembler.Block(index: 1, runs: [run(["先"])]),
        ]
        let node = assembler.assemble(seq: 1, blocks: blocks, isStreaming: false)
        XCTAssertEqual(node.markdown, "先\n\n后")
    }

    /// 空块不该产生多余的空行。
    func testEmptyBlocksSkipped() {
        let blocks = [
            AssistantAssembler.Block(index: 0, runs: [run(["有内容"])]),
            AssistantAssembler.Block(index: 1, runs: [run([])]),
            AssistantAssembler.Block(index: 2, runs: [run(["也有"])]),
        ]
        let node = assembler.assemble(seq: 1, blocks: blocks, isStreaming: false)
        XCTAssertEqual(node.markdown, "有内容\n\n也有")
    }

    func testStreamingFlagCarries() {
        let block = AssistantAssembler.Block(index: 0, runs: [run(["写到一半"])])
        XCTAssertTrue(assembler.assemble(seq: 1, block: block, isStreaming: true).isStreaming)
    }

    // MARK: - 未闭合围栏

    /// 流式文本随时可能停在围栏代码块中间。
    ///
    /// 不处理的话，渲染结果会在每个 token 之间剧烈跳变：代码块忽然张开、
    /// 闭合后字体又忽然从正文变等宽。
    func testDetectsOpenFence() {
        XCTAssertTrue(AssistantAssembler.hasOpenFence("前言\n```swift\nlet x = 1"))
    }

    func testClosedFenceIsNotOpen() {
        XCTAssertFalse(AssistantAssembler.hasOpenFence("```swift\nlet x = 1\n```"))
    }

    func testNoFenceIsNotOpen() {
        XCTAssertFalse(AssistantAssembler.hasOpenFence("只是普通文字"))
    }

    /// 两个完整的代码块仍然算闭合。
    func testTwoClosedFencesAreNotOpen() {
        XCTAssertFalse(AssistantAssembler.hasOpenFence("```a\n1\n```\n文字\n```b\n2\n```"))
    }

    func testThirdFenceReopens() {
        XCTAssertTrue(AssistantAssembler.hasOpenFence("```a\n1\n```\n```b\n2"))
    }

    // MARK: - 安全渲染前缀

    /// 最后一行在流式中总是可能被继续写，所以不算安全。
    func testLastLineIsNeverSafe() {
        let text = "第一行\n第二行\n正在写的第三行"
        let prefix = AssistantAssembler.safeRenderPrefix(text)
        let rendered = String(text.prefix(prefix))
        XCTAssertTrue(rendered.hasPrefix("第一行\n第二行"))
        XCTAssertFalse(rendered.contains("正在写的第三行"))
    }

    /// 未闭合围栏内的所有行都不安全——它们的语义取决于围栏是否闭合。
    func testOpenFenceContentIsNotSafe() {
        let text = "前言\n```swift\nlet x = 1\nlet y = 2"
        let prefix = AssistantAssembler.safeRenderPrefix(text)
        let rendered = String(text.prefix(prefix))
        XCTAssertEqual(rendered, "前言\n")
        XCTAssertFalse(rendered.contains("let x"))
    }

    /// 围栏闭合后，整块就安全了。
    func testClosedFenceBecomesSafe() {
        let text = "前言\n```swift\nlet x = 1\n```\n后续\n还在写"
        let prefix = AssistantAssembler.safeRenderPrefix(text)
        let rendered = String(text.prefix(prefix))
        XCTAssertTrue(rendered.contains("let x = 1"))
        XCTAssertTrue(rendered.contains("```"))
        XCTAssertFalse(rendered.contains("还在写"))
    }

    func testSingleLineHasNoSafePrefix() {
        XCTAssertEqual(AssistantAssembler.safeRenderPrefix("就一行"), 0)
    }

    func testEmptyTextHasNoSafePrefix() {
        XCTAssertEqual(AssistantAssembler.safeRenderPrefix(""), 0)
    }

    // MARK: - 表格分隔行

    func testRecognizesTableSeparator() {
        XCTAssertTrue(AssistantAssembler.isTableSeparator("|---|---|"))
        XCTAssertTrue(AssistantAssembler.isTableSeparator("| --- | --- |"))
        XCTAssertTrue(AssistantAssembler.isTableSeparator("|:---|---:|"))
    }

    func testTableRowIsNotSeparator() {
        XCTAssertFalse(AssistantAssembler.isTableSeparator("| 名称 | 值 |"))
    }

    func testNonTableLineIsNotSeparator() {
        XCTAssertFalse(AssistantAssembler.isTableSeparator("--- "))
    }

    // MARK: - 代码高亮

    /// 只覆盖实测出现过的语言。其余单色显示，这是明确降级不是遗漏。
    func testMeasuredLanguagesHighlight() {
        for language in ["swift", "powershell", "bash", "js", "ts", "json", "yaml", "java", "cpp", "python"] {
            XCTAssertTrue(
                AssistantAssembler.shouldHighlight(language),
                "\(language) 在实测里出现过，应该高亮"
            )
        }
    }

    func testLanguageMatchIsCaseInsensitive() {
        XCTAssertTrue(AssistantAssembler.shouldHighlight("Swift"))
        XCTAssertTrue(AssistantAssembler.shouldHighlight("JSON"))
    }

    func testUnmeasuredLanguageDoesNotHighlight() {
        XCTAssertFalse(AssistantAssembler.shouldHighlight("brainfuck"))
        XCTAssertFalse(AssistantAssembler.shouldHighlight("cobol"))
    }

    func testMissingLanguageDoesNotHighlight() {
        XCTAssertFalse(AssistantAssembler.shouldHighlight(nil))
    }
}
