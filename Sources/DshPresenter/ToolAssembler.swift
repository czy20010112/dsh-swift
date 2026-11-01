import Foundation
import DshSession

/// 把 `tool/call` 与 `tool/result` 装配成 `.tool` 节点。
///
/// 规模依据（326 个会话 / 523,473 条事件）：工具事件占 18.3% 的条数、**49.6% 的体积**
/// （结果 98.3 MB + 参数 38.8 MB）。所以这里的设计目标是"默认不把体积放进 cell"。
///
/// 一条铁律：卡片只能从四件套推导 —— `arguments` 字符串、`result.content`、
/// `result.error`、`result.meta`。host 侧的 `presentCall`/`presentResult` **不过线**，
/// 所以不存在"服务端下发卡片结构"这种东西可以白拿。
public struct ToolAssembler: Sendable {

    public init() {}

    /// 一次工具调用的原始素材。
    public struct Call: Sendable, Equatable {
        public var seq: EventSeq
        public var callId: String
        public var name: String
        /// 原始 arguments 字符串（host 就是按字符串存的，不是对象）。
        ///
        /// 实测 47,955 次调用里**零个非法 JSON**，但仍然要能容错：
        /// 流式中途读到的 arguments 是不完整的。
        public var arguments: String

        public init(seq: EventSeq, callId: String, name: String, arguments: String) {
            self.seq = seq
            self.callId = callId
            self.name = name
            self.arguments = arguments
        }
    }

    /// 一次工具调用的结果。
    public struct Result: Sendable, Equatable {
        public var callId: String
        /// `result.content` 里所有 text 片段拼接后的文本。
        public var text: String
        public var isError: Bool

        public init(callId: String, text: String, isError: Bool) {
            self.callId = callId
            self.text = text
            self.isError = isError
        }
    }

    /// 已注册专用卡的工具名。
    ///
    /// 只有 5 个，因为实测这 5 个覆盖 **88.1%** 的调用
    /// （pwsh 53.9% / read 13.1% / edit 10.6% / write 7.8% / grep 4.3%），
    /// 而长尾有 55 种。照抄 web 端的 12 类专用卡是把预算花在 11.9% 上。
    ///
    /// `glob` 跟 `grep` 共用搜索卡，`write` 跟 `edit` 共用 diff 卡。
    static let specializedTools: Set<String> = [
        "pwsh", "read", "edit", "write", "grep", "glob",
    ]

    /// 参数摘要要优先显示哪个字段。
    ///
    /// 顺序来自实测字段频次：`description`(26,163) 和 `command`(25,850) 几乎总是成对
    /// 出现在 pwsh 上，而 `description` 是人话、`command` 是命令——收起态显示人话更有用。
    /// `file_path`(15,662) 是第三位，覆盖 read/edit/write/read_image。
    static let summaryFieldPriority: [String] = [
        "description",   // 26,163 次，agent 自己写的一句话说明
        "command",       // 25,850
        "file_path",     // 15,662
        "pattern",       // 2,293，grep
        "path",          // 2,263
        "url",           // 468，web_fetch
        "message",       // 538，send_message
        "job_id",        // 1,520
        "prompt",        // 272，subagent
        "name",          // 238
        "target",        // 345
        "todos",         // 231，todo_write 唯一的参数
        "queries",       // 269，web_search
    ]

    /// 收起态里结果最多显示多少字符。
    ///
    /// 实测结果长度 p50=421 / p90=5,292 / p99=27,437 / max=128,705。
    /// 8 KB 这条线之上走"查看全文"，不整段塞进 cell —— 否则 p99 的那些调用
    /// 会让列表为了测一个 cell 的高度去排版两万多字。
    public static let inlineResultLimit = 8192

    /// 配对 call 与 result，产出节点。
    ///
    /// 用 `callId` 配对，不靠顺序 —— 工具可以并发，结果的到达顺序和调用顺序无关。
    ///
    /// - Parameters:
    ///   - calls: 窗口里的全部调用。
    ///   - results: 已到达的结果，按 callId 索引。
    public func assemble(
        calls: [Call],
        results: [String: Result]
    ) -> [ToolNode] {
        calls.map { call in
            let result = results[call.callId]
            return ToolNode(
                seq: call.seq,
                name: call.name,
                arguments: call.arguments,
                resultText: result?.text,
                isError: result?.isError ?? false,
                tier: Self.tier(for: call)
            )
        }
    }

    /// 判断这次调用该用哪一级卡片。
    static func tier(for call: Call) -> ToolCardTier {
        // 参数解不开就只能兜底：没有字段可以提取，只能原样显示。
        guard parseArguments(call.arguments) != nil else {
            return .raw
        }
        return specializedTools.contains(call.name) ? .specialized : .generic
    }

    /// 解析 arguments。失败返回 nil —— 调用方据此降到 L3 兜底卡。
    ///
    /// 失败的现实原因不是上游发了坏数据（实测零例），而是**流式中途**：
    /// `tool-call-chunks` 还没拼完时 arguments 是个残缺的 JSON 前缀。
    static func parseArguments(_ raw: String) -> [String: Any]? {
        guard !raw.isEmpty, let data = raw.data(using: .utf8) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return object as? [String: Any]
    }

    /// 收起态那一行显示的参数摘要。
    ///
    /// 按字段优先级取第一个命中的，截断到 160 个**字素簇**。
    /// 用字素而不是 UTF-16 offset，否则截断点可能落在一个 emoji 或组合字符中间。
    public func argumentSummary(for call: Call, limit: Int = 160) -> String {
        guard let args = Self.parseArguments(call.arguments) else {
            // 兜底：原样截断
            return Self.truncate(call.arguments, to: limit)
        }
        for field in Self.summaryFieldPriority {
            guard let value = args[field] else { continue }
            if let text = Self.stringify(value), !text.isEmpty {
                return Self.truncate(text, to: limit)
            }
        }
        // 没命中任何已知字段（长尾工具的自定义参数）：列出字段名，
        // 至少让用户知道这次调用带了什么。
        let keys = args.keys.sorted()
        guard !keys.isEmpty else { return "" }
        return Self.truncate(keys.joined(separator: ", "), to: limit)
    }

    /// 把 JSON 值转成一行可读文本。
    static func stringify(_ value: Any) -> String? {
        switch value {
        case let text as String:
            return text
        case let number as NSNumber:
            return number.stringValue
        case let flag as Bool:
            return flag ? "true" : "false"
        case let array as [Any]:
            // 数组摘要只说个数，展开才看内容
            return array.isEmpty ? nil : "\(array.count) 项"
        case is [String: Any]:
            return nil  // 嵌套对象在一行里没有意义，交给下一个字段
        default:
            return nil
        }
    }

    /// 按字素簇截断，超出加省略号。
    static func truncate(_ text: String, to limit: Int) -> String {
        // 先把换行压成空格：摘要是一行，保留换行会让它看起来像空的
        let flattened = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard flattened.count > limit else { return flattened }
        return String(flattened.prefix(limit)) + "…"
    }

    /// 结果的收起态摘要：行数 + 首行。
    ///
    /// 显示行数是因为工具输出最常被问的问题是"有没有东西"和"多不多"，
    /// 而不是具体内容 —— 具体内容展开看。
    public func resultSummary(for node: ToolNode) -> String? {
        guard let text = node.resultText else { return nil }
        if text.isEmpty { return "无输出" }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let first = Self.truncate(String(lines.first ?? ""), to: 120)
        if lines.count <= 1 { return first }
        return "\(first) · \(lines.count) 行"
    }

    /// 结果是否超过内联上限，需要走"查看全文"。
    public func needsFullTextView(_ node: ToolNode) -> Bool {
        (node.resultText?.count ?? 0) > Self.inlineResultLimit
    }
}
