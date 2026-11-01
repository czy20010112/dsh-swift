/// 一条事件在**对话记录**里扮演什么角色。
///
/// 会话日志里有两条平行的视图：
/// - **surface**：模型看到的上下文。`replace` 会遮蔽一段旧内容，换上新内容
///   （压缩后的摘要、改写过的工具结果……）；
/// - **transcript**：人看到的对话记录。它只由 `append` 来源的事件构成，
///   被遮蔽的内容**照常显示**——用户已经看过它们了。
///
/// host 的 web 客户端就是这么分的（`dsh-client-ui-chat` 的 `isAppendSurfaceEvent` /
/// `isReplacementSurfaceEvent`）。早期本仓库把 replace 当成"删掉区间再插入"，
/// 回放真实会话时发现压缩一次会抹掉最多 1,298 个 seq 的历史，才改成现在这样。
public enum SurfaceRole: Sendable, Equatable {
    /// 普通的对话记录素材，照常装配进正文。
    case transcript
    /// 只给模型看的替换副本，不进正文。
    ///
    /// 实测的来源：`tool/result` 91 次（一个调用的第二个结果总是 replace）、
    /// `system/message` 22 次、`user/message` 的 `plugin` 来源 6 次。
    case modelOnly(shadows: ClosedRange<EventSeq>)
    /// 压缩检查点。不显示它本身的内容（那是写给模型的摘要），但要在它的位置
    /// 放一个"上下文已压缩"的标记，让用户知道模型从这里开始看不到更早的细节。
    ///
    /// 实测 35 次，全是 `user/message` 且 `source.kind == compact-checkpoint`。
    case compactionCheckpoint(compactionId: String?, shadows: ClosedRange<EventSeq>)
    /// 不是 surface 事件（tool/call、turn/start、流分片……），surface 规则不适用。
    case notSurface

    /// 会进入 surface 的事件类型。只有这五种带 `surfaceOp`
    /// （实测这五种事件 100% 带 surfaceOp，其余类型 0% 带）。
    public static let surfaceEventTypes: Set<String> = [
        "system/message",
        "developer/message",
        "user/message",
        "assistant/message",
        "tool/result",
    ]

    /// `user/message` 里标记压缩检查点的来源。
    public static let compactCheckpointKind = "compact-checkpoint"

    /// 判定一条事件的角色。
    ///
    /// - Parameters:
    ///   - sourceKind: `user/message` 的 `source.kind`；其余类型传 nil。
    ///   - compactionId: 检查点带的压缩 id，用来和 `compaction/summary` 关联。
    public static func classify(
        type: String,
        surfaceOp: SurfaceOp?,
        sourceKind: String?,
        compactionId: String? = nil
    ) -> SurfaceRole {
        guard surfaceEventTypes.contains(type) else { return .notSurface }
        switch surfaceOp {
        case .replace(let start, let end):
            // 端点颠倒的区间不信任：按空区间处理，不让一个坏事件把范围算反
            let range = start <= end ? start...end : start...start
            if type == "user/message", sourceKind == compactCheckpointKind {
                return .compactionCheckpoint(compactionId: compactionId, shadows: range)
            }
            return .modelOnly(shadows: range)
        case .append, .other, nil:
            // 未知 op 和缺失 op 按 append 处理：宁可多显示一条，也不要让内容消失
            return .transcript
        }
    }

    /// 这条事件要不要装配进正文。
    public var entersTranscript: Bool {
        switch self {
        case .transcript, .notSurface: return true
        case .modelOnly, .compactionCheckpoint: return false
        }
    }
}

extension SessionEvent {
    /// 这条事件在对话记录里的角色。
    public var surfaceRole: SurfaceRole {
        var sourceKind: String?
        var compactionId: String?
        if case .message(let message) = payload {
            sourceKind = message.sourceKind
            compactionId = message.compactionId
        }
        return SurfaceRole.classify(
            type: type,
            surfaceOp: surfaceOp,
            sourceKind: sourceKind,
            compactionId: compactionId
        )
    }
}
