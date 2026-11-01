import Foundation
import DshSession

/// 正文里的一行（或一组）。
///
/// 节点种类与**真实数据分布**对齐，而不是照抄 web 端的 19 种。依据是本机 326 个会话 /
/// 523,473 条事件的统计（见 `docs/UI-DESIGN-FROM-DATA.md`）：
///
/// - `reasoning-chunks` 占全部事件的 44.3%、正文体积的 28.9% → `.reasoning` 是第一等公民；
/// - `tool/call` + `tool/result` 占 18.3%、体积 49.6% → `.tool` 默认收起；
/// - `assistant` 正文只占体积的 1.8%，但那是用户唯一真正要读的东西 → 永不收起；
/// - `user/message` 里只有 28.9% 是真人写的 → `.user` 走白名单。
public enum ChatNode: Sendable, Equatable {

    /// 真人发言。**只有** `source.kind ∈ {user, user-question-reply}` 才算。
    ///
    /// 实测 71% 的 `user/message` 是注入（skill-catalog / agent-instructions /
    /// runtime-context / subagent-settled / tool-jobs / team-message …共 18 种）。
    /// 必须白名单渲染，黑名单会漏——本样本里会多出 2,466 条假用户气泡。
    case user(UserNode)

    /// 思考过程。默认收起成一行摘要，展开才渲染全文。
    ///
    /// 这是性能主路径：44.3% 的事件都走这里。流式期间只更新"字数/秒数"，
    /// 不逐 token 重排版面。
    case reasoning(ReasoningNode)

    /// 一次工具调用及其结果。默认收起。
    case tool(ToolNode)

    /// 助手正文。Markdown 渲染，不收起。
    case assistant(AssistantNode)

    /// 轮次尾：用量、耗时、上下文占用。
    case turnTail(TurnTailNode)

    /// 排队中的下一步/下一轮输入。来自 `agent/inbox/spliced`。
    ///
    /// 实测 4,585 次，**比真人发言(1,005)还多**，不是罕见事件。默认收起显示一行摘要。
    case inbox(InboxNode)

    /// 上下文压缩的标记。
    ///
    /// 放在压缩检查点的位置，内容不显示（那是写给模型的摘要）。它告诉用户：
    /// 从这里往前的细节模型已经看不到了——之后它"忘了"之前说过的话不是 bug。
    /// 实测 35 个检查点，最宽遮蔽 1,298 个 seq。
    case compaction(CompactionNode)

    /// LLM 调用失败、正在重试。
    ///
    /// 重试期间界面上什么都不动，不显示的话用户分不清是卡住了还是在等。
    /// 实测 260 次，`TRANSPORT` 这类错误常常连续重试好几轮。
    case retry(RetryNotice)

    /// 用户执行的斜杠命令（`/permission danger-full-access` 之类）及其结果。
    ///
    /// run 和 done 按 commandId 合成一个节点：分开显示会出现"命令"和"结果"
    /// 两行，中间可能隔着别的事件。
    case command(CommandNode)

    /// 待办清单的当前状态。
    ///
    /// `todo/write` 每次都是全量。正文里只在它出现的位置显示那一刻的清单；
    /// "最新的清单"另由渲染层放在会话头或侧栏。
    case todo(TodoNode)

    /// agent 交付的文件。
    case deliverables(DeliverablesNode)

    // 这里刻意**没有**"过程组"节点。设计文档把"连续工具折叠成一个过程区"
    // 当成必做项，但实测 39,847 个连续工具段里 81.3% 只有 1 个调用、
    // p99 是 3 个、最长 8 个——根本没有"一串工具"可折叠。
    //
    // 原因在打断分布上：`assistant/message` 占全部分组打断的 97.8%，
    // agent 的节奏是"说一句 → 调一个工具 → 再说一句"。
    // 把 2 个调用折叠成「读取 2 个文件」只是多一次点击。

    /// 认不出来的东西。永不崩，显示最小可读形式。
    ///
    /// 必要性：事件词表随插件漂移（三方样本分别是 54 / 47 / 39 种），
    /// 所以"未知"是常态而非异常。
    case unknown(UnknownNode)
}

public struct UserNode: Sendable, Equatable {
    public var seq: EventSeq
    public var text: String
    public init(seq: EventSeq, text: String) {
        self.seq = seq
        self.text = text
    }
}

public struct ReasoningNode: Sendable, Equatable {
    public var seq: EventSeq
    /// 累加后的全文。收起态不读它。
    public var text: String
    /// 收起态显示的字数。用字素簇计数，不用 UTF-16 offset。
    public var characterCount: Int
    /// 思考耗时（秒）。流式期间持续增长。
    public var duration: Double
    /// 是否还在流式增长中。
    public var isStreaming: Bool

    public init(
        seq: EventSeq,
        text: String,
        characterCount: Int,
        duration: Double,
        isStreaming: Bool
    ) {
        self.seq = seq
        self.text = text
        self.characterCount = characterCount
        self.duration = duration
        self.isStreaming = isStreaming
    }
}

public struct ToolNode: Sendable, Equatable {
    public var seq: EventSeq
    /// 线上的工具名，原样保留（可能是 `mcp__foo__bar` 这种）。
    public var name: String
    /// 原始 arguments 字符串。实测 p50=386、p99=7,835、max=76,093 字符。
    public var arguments: String
    /// 结果文本。实测 p50=421、p99=27,437、max=128,705 字符。
    /// 超过 8 KB 的部分不进 cell，走"查看全文"。
    public var resultText: String?
    /// 结果是否是错误。
    public var isError: Bool
    /// 卡片降级档位。
    public var tier: ToolCardTier

    public init(
        seq: EventSeq,
        name: String,
        arguments: String,
        resultText: String?,
        isError: Bool,
        tier: ToolCardTier
    ) {
        self.seq = seq
        self.name = name
        self.arguments = arguments
        self.resultText = resultText
        self.isError = isError
        self.tier = tier
    }
}

/// 工具卡的三级降级。
///
/// 实测前 5 个工具（pwsh 53.9% / read 13.1% / edit 10.6% / write 7.8% / grep 4.3%）
/// 占全部调用的 **88.1%**，长尾有 55 种（含全部 MCP 与 dev_* 工具）。
/// 所以 L1 只做那 5 个就够，不必照抄 web 端的 12 类。
public enum ToolCardTier: Sendable, Equatable {
    /// 专用卡：终端 / 读取 / 编辑 diff / 搜索。覆盖 88.1%。
    case specialized
    /// 通用卡：工具名 + 参数摘要 + 结果纯文本 + 可展开 JSON。覆盖剩余 11.9%。
    case generic
    /// 兜底：参数非法或结果不可解析时，原样等宽显示。
    case raw
}

public struct AssistantNode: Sendable, Equatable {
    public var seq: EventSeq
    public var markdown: String
    public var isStreaming: Bool
    public init(seq: EventSeq, markdown: String, isStreaming: Bool) {
        self.seq = seq
        self.markdown = markdown
        self.isStreaming = isStreaming
    }
}

public struct TurnTailNode: Sendable, Equatable {
    public var seq: EventSeq
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var elapsed: Double?
    public init(seq: EventSeq, inputTokens: Int?, outputTokens: Int?, elapsed: Double?) {
        self.seq = seq
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.elapsed = elapsed
    }
}

public struct InboxNode: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case nextStep
        case nextTurn
    }
    public var seq: EventSeq
    public var kind: Kind
    public var summary: String
    public init(seq: EventSeq, kind: Kind, summary: String) {
        self.seq = seq
        self.kind = kind
        self.summary = summary
    }
}

public struct UnknownNode: Sendable, Equatable {
    public var seq: EventSeq
    /// 原始事件类型，照原样显示，便于排查。
    public var type: String
    public init(seq: EventSeq, type: String) {
        self.seq = seq
        self.type = type
    }
}

public struct CompactionNode: Sendable, Equatable {
    public var seq: EventSeq
    public init(seq: EventSeq) {
        self.seq = seq
    }
}

public struct CommandNode: Sendable, Equatable {
    public var seq: EventSeq
    public var commandId: String
    public var name: String
    public var args: String?
    /// `success` / `error` 等。还没完成时为 nil。
    public var outcome: String?
    public var outcomeText: String?

    public init(seq: EventSeq, commandId: String, name: String, args: String?,
                outcome: String? = nil, outcomeText: String? = nil) {
        self.seq = seq
        self.commandId = commandId
        self.name = name
        self.args = args
        self.outcome = outcome
        self.outcomeText = outcomeText
    }

    /// 一行显示：`/permission danger-full-access`。
    /// args 在线上带前导空格（实测 `" danger-full-access"`），要去掉再拼。
    public var displayLine: String {
        let trimmed = args?.trimmingCharacters(in: .whitespaces) ?? ""
        return trimmed.isEmpty ? "/\(name)" : "/\(name) \(trimmed)"
    }
}

public struct TodoNode: Sendable, Equatable {
    public var seq: EventSeq
    public var items: [DshSession.TodoItem]
    public init(seq: EventSeq, items: [DshSession.TodoItem]) {
        self.seq = seq
        self.items = items
    }

    /// 收起态：`待办 2/7`（已完成/总数）。
    public var summary: String {
        let done = items.filter { $0.status == "completed" }.count
        return "待办 \(done)/\(items.count)"
    }
}

public struct DeliverablesNode: Sendable, Equatable {
    public var seq: EventSeq
    public var files: [DshSession.DeliverableFile]
    public init(seq: EventSeq, files: [DshSession.DeliverableFile]) {
        self.seq = seq
        self.files = files
    }
}
