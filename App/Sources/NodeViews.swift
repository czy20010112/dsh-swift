import SwiftUI
import DshSession
import DshPresenter

// 正文节点的视图。只做"把 ChatNode 画出来"这一件事：摘要、截断、白名单这些判断
// 全部在 DshPresenter 里完成并有测试，这里不重复做。
//
// 只用 iOS 15 已有的 API：不用 NavigationStack、Grid、ViewThatFits、.scrollContentBackground
// 这类 iOS 16+ 的东西。本机没有 Mac，渲染层只能靠 CI 编译，写错一个 API 就是一轮 CI。

struct NodeView: View {
    let node: ChatNode

    var body: some View {
        switch node {
        case .user(let n): UserBubble(node: n)
        case .reasoning(let n): ReasoningRow(node: n)
        case .tool(let n): ToolCard(node: n)
        case .assistant(let n): AssistantProse(node: n)
        case .compaction: Divider.labeled("上下文已压缩 · 模型看不到更早的细节")
        case .retry(let n): StatusLine(symbol: "arrow.clockwise", text: n.summary, tint: .orange)
        case .command(let n): CommandRow(node: n)
        case .todo(let n): TodoRow(node: n)
        case .deliverables(let n): DeliverablesRow(node: n)
        case .inbox(let n): StatusLine(symbol: "tray", text: n.summary, tint: .secondary)
        case .turnTail: EmptyView()
        case .unknown(let n): StatusLine(symbol: "questionmark.circle", text: n.type, tint: .secondary)
        }
    }
}

// MARK: - 用户

private struct UserBubble: View {
    let node: UserNode

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            Text(node.text)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

// MARK: - 思考

/// 默认收起，只显示「思考 12.4 秒 · 3.4k 字」。
///
/// 思考占全部事件的 44.3%、正文体积的 94.3%。默认展开的话，每轮要先滚过
/// 几千字才看得到结论。收起态的两个数字变化不影响行高，流式期间可以每帧更新。
private struct ReasoningRow: View {
    let node: ReasoningNode
    @State private var expanded = false
    private let assembler = ReasoningAssembler()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                    Text(assembler.collapsedSummary(node))
                        .font(.footnote)
                    if node.isStreaming {
                        ProgressView().scaleEffect(0.6)
                    }
                }
                .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)

            if expanded {
                Text(node.text)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .padding(.leading, 14)
            }
        }
    }
}

// MARK: - 工具

/// 默认只显示工具名 + 一行参数摘要 + 一行结果摘要。
///
/// 工具结果占正文体积的 49.6%，p99 一条就有 27k 字。展开后超过 8 KB 的部分不进
/// 这个视图，走"查看全文"——否则列表为了测一个高度要排版两万多字。
private struct ToolCard: View {
    let node: ToolNode
    @State private var expanded = false
    @State private var showingFull = false
    private let assembler = ToolAssembler()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                expanded.toggle()
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        statusIcon
                        Text(node.name)
                            .font(.footnote.monospaced().weight(.semibold))
                        Text(assembler.argumentSummary(for: node, limit: 80))
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    if !expanded, let summary = assembler.resultSummary(for: node) {
                        Text(summary)
                            .font(.caption.monospaced())
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .padding(.leading, 22)
                    }
                }
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    MonoBlock(title: "参数", text: node.arguments)
                    if let result = node.resultText {
                        if assembler.needsFullTextView(node) {
                            MonoBlock(title: "结果（前 8 KB）",
                                      text: String(result.prefix(ToolAssembler.inlineResultLimit)))
                            Button("查看全文（\(TextSummary.compactCount(result.count)) 字）") {
                                showingFull = true
                            }
                            .font(.footnote)
                        } else {
                            MonoBlock(title: "结果", text: result)
                        }
                    }
                }
                .padding(.leading, 22)
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .sheet(isPresented: $showingFull) {
            FullTextSheet(title: node.name, text: node.resultText ?? "")
        }
    }

    @ViewBuilder private var statusIcon: some View {
        if node.resultText == nil {
            ProgressView().scaleEffect(0.6).frame(width: 16, height: 16)
        } else if node.isError {
            Image(systemName: "xmark.circle.fill").foregroundColor(.red)
        } else {
            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
        }
    }
}

private struct MonoBlock: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundColor(.secondary)
            Text(text.isEmpty ? "（空）" : text)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct FullTextSheet: View {
    let title: String
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                Text(text)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

// MARK: - 正文

/// 助手正文：唯一永不收起的节点。
///
/// iOS 15 的 `AttributedString(markdown:)` 支持行内样式（粗体、斜体、行内代码、链接），
/// 正好覆盖实测最高频的两项：行内代码 34.4%、粗体 29.6%。块级结构（围栏代码、表格、
/// 列表）它不处理，先按段落拆开、围栏块单独用等宽显示，够第一版用。
private struct AssistantProse: View {
    let node: AssistantNode

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.blocks(node.markdown).enumerated()), id: \.offset) { _, block in
                switch block {
                case .prose(let text):
                    Text(Self.inline(text))
                        .textSelection(.enabled)
                case .code(let text):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(text)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .padding(8)
                    }
                    .background(Color(.tertiarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    enum Block {
        case prose(String)
        case code(String)
    }

    /// 按围栏代码块切分。未闭合的围栏（流式中途）把剩余部分当代码，避免闭合时字体跳变。
    static func blocks(_ markdown: String) -> [Block] {
        var result: [Block] = []
        var buffer: [Substring] = []
        var inFence = false
        func flush() {
            let text = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { result.append(inFence ? .code(text) : .prose(text)) }
            buffer.removeAll()
        }
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                flush()
                inFence.toggle()
                continue
            }
            buffer.append(line)
        }
        flush()
        return result
    }

    /// 行内 Markdown。解析失败（比如流式中途留了半个 `**`）退回纯文本，不能空白。
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

// MARK: - 其余

private struct CommandRow: View {
    let node: CommandNode

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(node.name.isEmpty ? "命令" : node.displayLine)
                .font(.footnote.monospaced())
            if let text = node.outcomeText {
                Text(text)
                    .font(.caption)
                    .foregroundColor(node.outcome == "success" ? .secondary : .red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TodoRow: View {
    let node: TodoNode
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                expanded.toggle()
            } label: {
                Label(node.summary, systemImage: "checklist")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            if expanded {
                ForEach(Array(node.items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: Self.symbol(item.status))
                            .foregroundColor(item.status == "completed" ? .green : .secondary)
                        Text(item.content).font(.footnote)
                    }
                }
                .padding(.leading, 6)
            }
        }
    }

    static func symbol(_ status: String) -> String {
        switch status {
        case "completed": return "checkmark.circle.fill"
        case "in_progress": return "circle.dashed"
        default: return "circle"
        }
    }
}

private struct DeliverablesRow: View {
    let node: DeliverablesNode

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(node.files.enumerated()), id: \.offset) { _, file in
                VStack(alignment: .leading, spacing: 1) {
                    Label((file.path as NSString).lastPathComponent, systemImage: "doc")
                        .font(.footnote.weight(.medium))
                    if let description = file.description {
                        Text(description).font(.caption).foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.3)))
    }
}

private struct StatusLine: View {
    let symbol: String
    let text: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption)
            .foregroundColor(tint)
    }
}

private extension Divider {
    /// 中间带说明文字的分隔线。
    static func labeled(_ text: String) -> some View {
        HStack(spacing: 8) {
            VStack { Divider() }
            Text(text).font(.caption2).foregroundColor(.secondary).fixedSize()
            VStack { Divider() }
        }
    }
}
