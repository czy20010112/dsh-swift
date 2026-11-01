/// 落盘的 assistant 流分片。
///
/// 实时流是逐 delta 到达的，但**历史和重连拿到的是压缩形式**：连续的同类分片被
/// 合成一条 run，时间戳存成差值数组。客户端必须能把它展开回逐分片的形式，
/// 否则历史消息的内容和时间都是错的。
///
/// 两种代际的落盘位置不同（实测 326 个会话：56 个旧代、257 个 v4）：
/// - 旧代：`reasoning-chunks` / `text-chunks` / `tool-call-chunks` 是**顶层行**，
///   带 `seq0` + `time0`；
/// - v4：同样的结构**嵌在** `assistant/message` 的 `data.stream` 数组里，
///   只带 `time0`（没有 seq0，因为整条 message 共用一个 seq）。
///
/// 两代都要能读——同一份客户端要能打开用户的旧会话。
public enum StreamRun: Sendable, Equatable {

    /// 一段连续的文本分片。
    case text(ChunkRun)
    /// 一段连续的思考分片。
    ///
    /// 实测这是最大的一类：占全部事件的 44.3%、正文体积的 94.3%。
    case reasoning(ChunkRun)
    /// 一段连续的工具参数分片（工具的 arguments 也是流式拼出来的）。
    case toolCall(ChunkRun)
    /// 单个非 run 的控制分片，如 `block-start` / `block-stop`。
    case control(ControlChunk)
}

/// 一条压缩 run：n 个文本分片共用一个起始时间和一组时间差。
public struct ChunkRun: Sendable, Equatable {
    /// 内容块身份。
    ///
    /// **这不是分片序号**。同一个块的每个 delta 都重复同一个 `index`；
    /// 把它当分片序号用，一段回复会塌成"一字一行"。
    public var index: Int
    /// 第一个分片的时间（毫秒）。
    public var time0: Int64
    /// 相邻分片的时间差（毫秒）。
    ///
    /// **长度是 `texts.count - 1`**：第一个分片的时间就是 `time0`，
    /// 之后每个分片累加一个 dt。实测样本里 texts=11 / dt=10、texts=10 / dt=9，
    /// 都符合这个关系。
    public var dt: [Int]
    /// 各分片的文本。累加起来才是这个块的完整内容。
    public var texts: [String]

    public init(index: Int, time0: Int64, dt: [Int], texts: [String]) {
        self.index = index
        self.time0 = time0
        self.dt = dt
        self.texts = texts
    }
}

/// 流里的控制分片。
public struct ControlChunk: Sendable, Equatable {
    public var time: Int64
    /// 如 `block-start` / `block-stop`。
    public var kind: String
    public var index: Int?
    /// `block-start` 带的块类型：`text` / `tool-call` / `reasoning` 等。
    public var blockType: String?

    public init(time: Int64, kind: String, index: Int?, blockType: String?) {
        self.time = time
        self.kind = kind
        self.index = index
        self.blockType = blockType
    }
}

/// 展开后的单个分片。
public struct ExpandedChunk: Sendable, Equatable {
    public var index: Int
    public var time: Int64
    public var text: String

    public init(index: Int, time: Int64, text: String) {
        self.index = index
        self.time = time
        self.text = text
    }
}

public enum AssistantStream {

    /// 把一条压缩 run 展开成逐分片形式，还原每个分片的绝对时间。
    ///
    /// 时间的还原规则：第 0 个分片 = `time0`，第 i 个分片 = `time0 + dt[0..<i]` 之和。
    ///
    /// `dt` 比 `texts` 短一个是正常的。如果 `dt` 更短（截断的历史），
    /// 缺失的部分按 0 处理——宁可时间戳偏早，也不要丢内容。
    public static func expand(_ run: ChunkRun) -> [ExpandedChunk] {
        var out: [ExpandedChunk] = []
        out.reserveCapacity(run.texts.count)
        var time = run.time0
        for (offset, text) in run.texts.enumerated() {
            if offset > 0 {
                // dt[i-1] 是第 i 个分片相对第 i-1 个的差值
                let delta = offset - 1 < run.dt.count ? run.dt[offset - 1] : 0
                time += Int64(delta)
            }
            out.append(ExpandedChunk(index: run.index, time: time, text: text))
        }
        return out
    }

    /// 一条 run 的完整文本。
    ///
    /// 这是"块内容"的定义：同一个 `index` 的所有分片拼接。不是替换——
    /// 发累计全文会让块内容被反复覆盖。
    public static func joinedText(_ run: ChunkRun) -> String {
        run.texts.joined()
    }

    /// 一条 run 覆盖的时间跨度（毫秒）。用于"思考了 12.4 秒"这类摘要。
    public static func duration(_ run: ChunkRun) -> Int {
        // 只累加真正用到的那部分 dt（texts.count - 1 个）
        let used = max(0, min(run.dt.count, run.texts.count - 1))
        return run.dt.prefix(used).reduce(0, +)
    }
}
