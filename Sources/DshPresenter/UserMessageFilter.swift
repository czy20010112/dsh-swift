import Foundation
import DshSession

/// 决定一条 `user/message` 要不要渲染成用户发言。
///
/// **这是白名单，不是黑名单**，而且这个选择有硬数据支撑：实测 3,474 条
/// `user/message` 里只有 **28.9%** 是真人写的（1,005 条 `user` + 3 条
/// `user-question-reply`）。其余 18 种来源都是注入：
///
/// ```
///  372 skill-catalog        358 subagent-settled    331 tool-jobs
///  329 team-message         309 agent-instructions  305 runtime-context
///  193 agent-message         76 plugin               54 ds-bot-time-context
///   47 model-selection       35 compact-checkpoint   15 goal
///   14 subagent-report       11 user-approval         8 time-context
///    4 tool-goal              3 bot                   2 repeat-tool-reminder
/// ```
///
/// 做成黑名单的后果：这批样本会刷出 **2,466 条**假的用户气泡，而且每次上游加一种
/// 新的注入来源就多一批。白名单的失效方向是安全的——漏渲染一条真人消息会被立刻
/// 发现，而多渲染 2,466 条注入只会让人觉得"这 App 坏了"。
public struct UserMessageFilter: Sendable {

    public init() {}

    /// 会渲染成用户发言的来源。只有这两种。
    ///
    /// `user-question-reply` 只出现 3 次（0.1%），但必须渲染——它是用户对
    /// `ask_user` 提问的答复，不显示的话对话里会出现"问了但没人答"的断裂。
    public static let renderedSources: Set<String> = [
        "user",
        "user-question-reply",
    ]

    /// 这条消息该不该出现在正文里。
    public func shouldRender(sourceKind: String?) -> Bool {
        guard let sourceKind else { return false }
        return Self.renderedSources.contains(sourceKind)
    }

    /// 从一条 `user/message` 装配用户节点。
    ///
    /// - Returns: `nil` 表示这条是注入，不渲染。
    public func node(
        seq: EventSeq,
        sourceKind: String?,
        texts: [String]
    ) -> UserNode? {
        guard shouldRender(sourceKind: sourceKind) else { return nil }
        let raw = texts.joined()

        // 提问答复的 text 是一个 JSON 载荷，不是人话。直接显示会让用户看到一坨 JSON。
        if sourceKind == "user-question-reply" {
            let readable = Self.readableAnswer(from: raw) ?? raw
            return UserNode(seq: seq, text: readable)
        }
        return UserNode(seq: seq, text: raw)
    }

    /// 从 `user-question-reply` 的 JSON 载荷里取出用户实际的回答。
    ///
    /// 载荷形状（实测）：
    /// ```json
    /// { "kind": "answer_to_pending_question", "tool": "ask_user",
    ///   "questions": [{ "id": "...", "question": "...", "options": [...] }],
    ///   "answers":   [{ "id": "...", "selected": [...], "custom": "..." }] }
    /// ```
    ///
    /// 用户的回答可能是选中的选项（`selected`），也可能是自己打的字（`custom`），
    /// 或者两者都有。按"先选项、再自定义"拼接。
    static func readableAnswer(from raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = root["answers"] as? [[String: Any]]
        else { return nil }

        var parts: [String] = []
        for answer in answers {
            var pieces: [String] = []
            if let selected = answer["selected"] as? [Any], !selected.isEmpty {
                let labels = selected.compactMap { item -> String? in
                    if let text = item as? String { return text }
                    // 选项也可能是对象，取它的 label
                    if let object = item as? [String: Any] {
                        return object["label"] as? String
                    }
                    return nil
                }
                pieces.append(contentsOf: labels)
            }
            if let custom = answer["custom"] as? String,
               !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pieces.append(custom)
            }
            if !pieces.isEmpty {
                parts.append(pieces.joined(separator: "、"))
            }
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "\n")
    }

    /// 被隐藏的来源要不要在"轨迹视图"里可见。
    ///
    /// 隐藏不等于丢弃：排查问题时需要看到 agent 到底被注入了什么。
    /// 这个方法区分"不渲染在正文"和"根本不保留"——目前所有注入都属于前者。
    public func isTraceable(sourceKind: String?) -> Bool {
        sourceKind != nil
    }
}
