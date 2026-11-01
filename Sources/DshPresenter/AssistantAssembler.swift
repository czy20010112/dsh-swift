import Foundation
import DshSession

/// 把助手正文装配成 `.assistant` 节点。
///
/// 正文只占全部体积的 **1.8%**（3.5 MB，对比 reasoning 的 57.2 MB），
/// 但这是用户唯一真正要读的东西——结论在这里。所以它是唯一**永不收起**的节点。
///
/// Markdown 的实现优先级由实测定（12,964 个含文本的块 / 366 万字符）：
///
/// ```
/// 34.4%  行内代码     ← 和粗体两项远超其他，必须最先做对
/// 29.6%  粗体
///  7.5%  无序列表
///  7.1%  标题
///  6.9%  表格
///  5.2%  围栏代码块
///  4.7%  有序列表
///  2.7%  斜体
///  2.1%  链接
///  1.3%  分割线
///  0.8%  引用
///  0.2%  图片
///  0.0%  删除线（5 次）
///    0   任务列表、LaTeX 公式  ← 实测零出现
/// ```
///
/// 两条由此而来的决定：
/// - **行内代码 + 粗体先做**。它们合起来覆盖 64% 的块，而且都是行内样式，
///   不影响块级布局，所以能在流式期间安全地增量渲染；
/// - **任务列表与 LaTeX 不做**。实测零出现，做了也没人看见。
///   数学公式若将来出现，按原文显示（设计文档已把这条写成明确降级）。
public struct AssistantAssembler: Sendable {

    public init() {}

    /// 正文里的一个内容块。
    ///
    /// 一次回复可能有多个块（文本、工具调用、图片交错），靠 `index` 区分。
    public struct Block: Sendable, Equatable {
        /// 内容块身份。**不是分片序号**——同一块的每个 delta 都重复这个值。
        public var index: Int
        public var runs: [ChunkRun]

        public init(index: Int, runs: [ChunkRun]) {
            self.index = index
            self.runs = runs
        }
    }

    /// 装配一个文本块。
    ///
    /// - Parameter isStreaming: 还在增长中。流式期间渲染层不做精确测高。
    public func assemble(
        seq: EventSeq,
        block: Block,
        isStreaming: Bool
    ) -> AssistantNode {
        AssistantNode(
            seq: seq,
            markdown: block.runs.map(AssistantStream.joinedText).joined(),
            isStreaming: isStreaming
        )
    }

    /// 把多个文本块合成一个节点。
    ///
    /// 同一次回复里的多个文本块之间要有段落间隔，否则两段话会黏在一起。
    public func assemble(
        seq: EventSeq,
        blocks: [Block],
        isStreaming: Bool
    ) -> AssistantNode {
        let ordered = blocks.sorted { $0.index < $1.index }
        let text = ordered
            .map { $0.runs.map(AssistantStream.joinedText).joined() }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        return AssistantNode(seq: seq, markdown: text, isStreaming: isStreaming)
    }

    /// 流式渲染时安全的截断点。
    ///
    /// 问题：流式文本随时可能停在一个**未闭合的 Markdown 结构**中间——
    /// 半个围栏代码块、半个表格、半个粗体标记。直接丢给解析器，渲染结果会在
    /// 每个 token 之间剧烈跳变（代码块忽然张开、表格忽然塌成一行文字）。
    ///
    /// 处置：找到最后一个"结构完整"的位置，只渲染到那里，剩下的尾巴按纯文本追加。
    /// 这样已渲染的部分不会回跳。
    ///
    /// - Returns: 可以安全交给 Markdown 解析器的前缀长度（字素簇计）。
    public static func safeRenderPrefix(_ markdown: String) -> Int {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        var fenceOpen = false
        var safeLineCount = 0

        for (offset, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                fenceOpen.toggle()
                // 围栏开启的那一行本身不安全：闭合标记还没来
                if fenceOpen { continue }
            }
            if fenceOpen { continue }

            // 表格的分隔行（|---|---|）必须和表头一起出现才算完整
            if Self.isTableSeparator(trimmed), offset > 0 {
                continue
            }
            // 最后一行在流式中总是可能被继续写，不算安全
            if offset == lines.count - 1 { continue }

            safeLineCount = offset + 1
        }

        guard safeLineCount > 0 else { return 0 }
        let safeLines = lines.prefix(safeLineCount)
        // +1 是每行后面的换行符，最后一行也有（因为它后面还有内容）
        return safeLines.reduce(0) { $0 + $1.count + 1 }
    }

    static func isTableSeparator(_ line: String) -> Bool {
        guard line.hasPrefix("|") else { return false }
        return line.allSatisfy { "|-: ".contains($0) }
    }

    /// 流式期间是否有未闭合的围栏代码块。
    ///
    /// 渲染层据此决定要不要给尾巴套一个临时的代码块样式——
    /// 否则用户会看到代码以正文字体显示，闭合后忽然变成等宽。
    public static func hasOpenFence(_ markdown: String) -> Bool {
        var open = false
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                open.toggle()
            }
        }
        return open
    }

    /// 代码块要高亮的语言。
    ///
    /// 只覆盖实测出现过的前 10 种（swift 163 / powershell 92 / bash 46 / js 27 /
    /// ts 18 / json 18 / yaml 17 / java 16 / cpp 12 / python 11）。
    /// 其余语言单色显示——这是明确的降级，不是遗漏。
    public static let highlightedLanguages: Set<String> = [
        "swift", "powershell", "bash", "js", "javascript", "ts", "typescript",
        "json", "jsonc", "yaml", "java", "cpp", "c", "python",
    ]

    /// 这个语言标记要不要高亮。
    public static func shouldHighlight(_ language: String?) -> Bool {
        guard let language else { return false }
        return highlightedLanguages.contains(language.lowercased())
    }
}
