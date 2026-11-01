import Foundation

/// 会话日志的代际。
///
/// 实测本机 357 个会话文件里有**三代**：v0（58 个）、v3（31 个）、v4（268 个）。
/// v0 的 header 带的是 `version: 0`，不是缺省——缺省也按 v0 认，兼容更早的文件。
///
/// 代际决定了两件事，所以必须先认出来：
/// - assistant 流分片在哪：v0 是顶层行，v3/v4 嵌在 `assistant/message` 的 `data.stream` 里；
/// - `tool/result` 的配对 id 在哪：只有 v4 有 `message.toolCallId`，v0/v3 只有 `message.source.callId`。
public enum SessionGeneration: Sendable, Equatable, Hashable {
    case v0
    case v3
    case v4
    /// 认不出的新版本。按 v4 的规则尽力解码，而不是拒收——用户升级 host 后，
    /// 客户端还没更新也得能打开会话。
    case future(Int)

    public init(version: Int?) {
        switch version {
        case nil, 0?: self = .v0
        case 3?: self = .v3
        case 4?: self = .v4
        case let other?: self = .future(other)
        }
    }
}

/// JSONL 的首行。
public struct SessionHeader: Sendable, Equatable, Decodable {
    public var id: String
    public var version: Int?
    public var cwd: String?
    public var createdAt: Int64?

    public var generation: SessionGeneration { SessionGeneration(version: version) }

    public init(id: String, version: Int?, cwd: String?, createdAt: Int64?) {
        self.id = id
        self.version = version
        self.cwd = cwd
        self.createdAt = createdAt
    }
}

/// 事件对窗口的作用方式。
public enum SurfaceOp: Sendable, Equatable {
    /// 线上是字符串 `"append"`。实测是最常见的形式，不是缺省值——缺省时字段不存在。
    case append
    /// 线上是对象。v3/v4 的键是 `startSeq`/`endSeq`，**v0 是 `start`/`end`**，
    /// 只认一种会让旧会话里的重写全部失效，表现为同一条消息出现两次。
    case replace(startSeq: EventSeq, endSeq: EventSeq)
    /// 认不出的 op。保留名字，交给上层决定是否忽略。
    case other(String)
}

/// 一条解码后的会话事件。
public struct SessionEvent: Sendable, Equatable {
    /// v0 顶层 run 行没有 `seq`，只有 `seq0`；这里统一成起始 seq。
    public var seq: EventSeq
    /// 这条事件占用的 seq 个数。
    ///
    /// v0 的顶层 run 一行代表 n 个分片，占用 `seq0 ..< seq0 + n`，下一条事件的 seq
    /// 就是 `seq0 + n`（实测 9,061 处无一例外）。按"每行占 1 个 seq"去推算断档，
    /// 旧会话会被误判成到处缺事件。其余事件都是 1。
    public var seqSpan: Int
    /// 毫秒。v0 顶层 run 行用 `time0`，其余用 `time`。
    public var time: Int64?
    public var type: String
    public var surfaceOp: SurfaceOp?
    /// 这条事件由哪些更早的事件派生（如 tool/result 指回触发它的那次调用）。
    public var sourceEventSeqs: [EventSeq]
    public var payload: EventPayload

    public init(
        seq: EventSeq,
        seqSpan: Int = 1,
        time: Int64?,
        type: String,
        surfaceOp: SurfaceOp?,
        sourceEventSeqs: [EventSeq],
        payload: EventPayload
    ) {
        self.seq = seq
        self.seqSpan = seqSpan
        self.time = time
        self.type = type
        self.surfaceOp = surfaceOp
        self.sourceEventSeqs = sourceEventSeqs
        self.payload = payload
    }
}

/// 事件内容。
///
/// 只对装配器真正要读的类型建模。其余类型（compaction/*、request/header 等几十种）
/// 一律走 `.unknown`：事件词表随插件漂移，为每一种都写结构只会让解码器跟着漂。
public enum EventPayload: Sendable, Equatable {
    /// v0 的顶层流分片：`*-chunks` 行，以及未压缩的 `assistant/chunk` 行。
    case stream(StreamItem)
    case assistantMessage(AssistantMessageEvent)
    /// 被重试作废的那次生成。结构和 assistant/message 的 stream 一样，但不进正文。
    case assistantAttempt(AssistantAttemptEvent)
    case toolCall(ToolCallEvent)
    case toolResult(ToolResultEvent)
    /// `user/message` / `system/message` / `developer/message`。
    case message(ConversationMessage)
    case turnStart(turn: Int)
    case turnEnd(turn: Int, reason: String?)
    case stepStart(turn: Int, step: Int)
    case stepEnd(turn: Int, step: Int)
    /// 没有建模的类型。保留类型名——它可能被 surfaceOp 或 sourceEventSeqs 引用。
    case unknown(type: String)
}

/// 流里的一项，附带 `ChunkRun` 装不下的工具身份。
public struct StreamItem: Sendable, Equatable {
    public var run: StreamRun
    /// 仅 `tool-call-chunks`：这段参数属于哪次调用。
    public var toolCallId: String?
    /// 仅 `tool-call-chunks`。实测 v4 里有 87 条 run 不带 name（同一调用的后续 run），
    /// 所以是可选的——要靠 `toolCallId` 回到第一条 run 或 tool/call 去拿名字。
    public var toolName: String?

    public init(run: StreamRun, toolCallId: String? = nil, toolName: String? = nil) {
        self.run = run
        self.toolCallId = toolCallId
        self.toolName = toolName
    }
}

public struct TokenUsage: Sendable, Equatable, Decodable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cacheReadTokens: Int?
}

/// assistant 消息的最终内容块。
public enum ContentBlock: Sendable, Equatable {
    case text(String)
    case reasoning(String)
    case toolCall(id: String, name: String, arguments: String)
    case other(type: String)
}

public struct AssistantMessageEvent: Sendable, Equatable {
    public var turn: Int?
    public var step: Int?
    public var content: [ContentBlock]
    /// v3/v4 才有；v0 的流分片是独立的顶层行，这里为空。
    public var stream: [StreamItem]
    public var usage: TokenUsage?
    public var model: String?
}

public struct AssistantAttemptEvent: Sendable, Equatable {
    public var turn: Int?
    public var step: Int?
    public var stream: [StreamItem]
}

public struct ToolCallEvent: Sendable, Equatable {
    public var turn: Int?
    public var step: Int?
    public var callId: String
    public var name: String
    /// 原样保留的 JSON **字符串**。不在这里解析：参数非法是要显示给用户的状态，不是解码错误。
    public var arguments: String
}

public struct ToolResultEvent: Sendable, Equatable {
    /// 配对 id 从哪个字段拿到的。
    ///
    /// 记下来是因为三代格式的位置不同，而配错只会让结果挂到别的卡片上、不会报错。
    public enum CallIdOrigin: Sendable, Equatable {
        /// v4：`message.toolCallId`
        case messageToolCallId
        /// v0/v3：`message.source.callId`
        case sourceCallId
        /// 兜底：`message.content[]` 里 `tool-result` 块的 `toolCallId`
        case resultBlock
        case missing
    }

    public var turn: Int?
    public var step: Int?
    public var callId: String?
    public var callIdOrigin: CallIdOrigin
    /// 所有文本块拼接。v0/v3 的文本嵌在 `tool-result` 块里面一层，这里已经展平。
    public var text: String
    public var isError: Bool
    /// 图片块个数。图片本体不进事件模型。
    public var imageCount: Int
}

public struct ConversationMessage: Sendable, Equatable {
    public var role: String?
    /// `source.kind`。区分真人发言与注入要靠它（见 ChatNode.user 的白名单说明）。
    public var sourceKind: String?
    /// 仅 `source.kind == compact-checkpoint`：这个检查点属于哪次压缩，
    /// 用来和 `compaction/start|summary|end` 关联。
    public var compactionId: String? = nil
    public var text: String
}

/// 单条事件解码失败的记录。
public struct EventDecodingFailure: Error, Sendable, Equatable {
    /// 尽量从坏行里抢救出来的类型和 seq，便于定位。
    public var type: String?
    public var seq: EventSeq?
    public var message: String
}

/// 逐元素容错的解码包装：一条坏事件不能让整个会话打不开。
public struct LossyDecoded<Value: Decodable & Sendable>: Decodable, Sendable {
    public var result: Result<Value, EventDecodingFailure>

    public init(from decoder: Decoder) throws {
        do {
            result = .success(try Value(from: decoder))
        } catch {
            let probe = try? EventProbe(from: decoder)
            result = .failure(EventDecodingFailure(
                type: probe?.type,
                seq: probe?.seq ?? probe?.seq0,
                message: String(describing: error)
            ))
        }
    }

    public var value: Value? {
        if case .success(let v) = result { return v }
        return nil
    }

    public var failure: EventDecodingFailure? {
        if case .failure(let f) = result { return f }
        return nil
    }
}

private struct EventProbe: Decodable {
    var type: String?
    var seq: Double?
    var seq0: Double?
}

/// 一整份会话日志的解码结果。
public struct DecodedSessionLog: Sendable {
    public var header: SessionHeader?
    public var events: [SessionEvent]
    public var failures: [EventDecodingFailure]
}

public enum EventDecoder {

    public static func decodeEvent(_ data: Data) throws -> SessionEvent {
        try JSONDecoder().decode(SessionEvent.self, from: data)
    }

    public static func decodeHeader(_ data: Data) throws -> SessionHeader {
        try JSONDecoder().decode(SessionHeader.self, from: data)
    }

    /// 解码已解压的 JSONL 文本。首行是 header，其余每行一个事件。
    ///
    /// 坏行记进 `failures` 而不是抛出：追加写的日志在崩溃后常见最后一行不完整，
    /// 为此拒绝整个会话是不划算的。
    public static func decodeJSONL(_ text: String) -> DecodedSessionLog {
        let decoder = JSONDecoder()
        var header: SessionHeader?
        var events: [SessionEvent] = []
        var failures: [EventDecodingFailure] = []
        var isFirst = true
        for line in text.split(whereSeparator: \.isNewline) where !line.isEmpty {
            let data = Data(line.utf8)
            if isFirst {
                isFirst = false
                if let h = try? decoder.decode(SessionHeader.self, from: data), !line.contains("\"seq") {
                    header = h
                    continue
                }
            }
            switch (try? decoder.decode(LossyDecoded<SessionEvent>.self, from: data))?.result {
            case .success(let e)?: events.append(e)
            case .failure(let f)?: failures.append(f)
            case nil: failures.append(EventDecodingFailure(type: nil, seq: nil, message: "不是 JSON 对象"))
            }
        }
        return DecodedSessionLog(header: header, events: events, failures: failures)
    }
}

extension SessionEvent {

    /// 这条事件携带的全部流项，不论它们在哪一代的哪个位置。
    public var streamItems: [StreamItem] {
        switch payload {
        case .stream(let item): return [item]
        case .assistantMessage(let m): return m.stream
        case .assistantAttempt(let a): return a.stream
        default: return []
        }
    }

    /// 落盘事件放进窗口时的记录形式。
    public var windowedRecord: WindowedRecord {
        WindowedRecord(seq: seq, type: type, isLive: false)
    }
}

// MARK: - 解码实现

extension SessionEvent: Decodable {

    private enum Keys: String, CodingKey {
        case type, seq, seq0, time, time0, surfaceOp, sourceEventSeqs, data
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        type = try c.decode(String.self, forKey: .type)
        // seq 按 Double 解：live 合成事件带小数 seq，用 Int 解会直接失败。
        guard let s = try c.decodeIfPresent(Double.self, forKey: .seq)
            ?? c.decodeIfPresent(Double.self, forKey: .seq0) else {
            throw DecodingError.keyNotFound(Keys.seq, .init(
                codingPath: c.codingPath, debugDescription: "既没有 seq 也没有 seq0"))
        }
        seq = s
        seqSpan = 1
        time = try c.decodeIfPresent(Int64.self, forKey: .time)
            ?? c.decodeIfPresent(Int64.self, forKey: .time0)
        surfaceOp = try c.decodeIfPresent(SurfaceOpDTO.self, forKey: .surfaceOp)?.value
        sourceEventSeqs = try c.decodeIfPresent([Double].self, forKey: .sourceEventSeqs) ?? []

        switch type {
        case "reasoning-chunks", "text-chunks", "tool-call-chunks":
            let run = try c.decode(RunDTO.self, forKey: .data)
            // v0 顶层行的 time0 在事件上，不在 data 里
            let item = run.streamItem(kind: type, fallbackTime0: time ?? 0)
            seqSpan = max(1, run.pieces.count)
            payload = .stream(item)
        case "assistant/chunk":
            let dto = try c.decode(LegacyChunkDTO.self, forKey: .data)
            payload = .stream(dto.chunk.streamItem(time: time ?? 0))
        case "assistant/message":
            let dto = try c.decode(AssistantMessageDTO.self, forKey: .data)
            payload = .assistantMessage(AssistantMessageEvent(
                turn: dto.turn,
                step: dto.step,
                content: dto.message?.content?.map(\.block) ?? [],
                stream: dto.stream?.map(\.item) ?? [],
                usage: dto.usage,
                model: dto.message?.source?.model
            ))
        case "assistant/attempt":
            let dto = try c.decode(AssistantMessageDTO.self, forKey: .data)
            payload = .assistantAttempt(AssistantAttemptEvent(
                turn: dto.turn, step: dto.step, stream: dto.stream?.map(\.item) ?? []))
        case "tool/call":
            let dto = try c.decode(ToolCallDTO.self, forKey: .data)
            payload = .toolCall(ToolCallEvent(
                turn: dto.turn, step: dto.step, callId: dto.callId, name: dto.name, arguments: dto.arguments))
        case "tool/result":
            payload = .toolResult(try c.decode(ToolResultDTO.self, forKey: .data).event)
        case "user/message", "system/message", "developer/message":
            payload = .message(try c.decode(MessageEnvelopeDTO.self, forKey: .data).message)
        case "turn/start":
            payload = .turnStart(turn: try c.decode(TurnDTO.self, forKey: .data).turn)
        case "turn/end":
            let dto = try c.decode(TurnDTO.self, forKey: .data)
            payload = .turnEnd(turn: dto.turn, reason: dto.reason?.kind)
        case "step/start":
            let dto = try c.decode(StepDTO.self, forKey: .data)
            payload = .stepStart(turn: dto.turn, step: dto.step)
        case "step/end":
            let dto = try c.decode(StepDTO.self, forKey: .data)
            payload = .stepEnd(turn: dto.turn, step: dto.step)
        default:
            // 不读 data：未知类型的结构不受我们控制，读它只会制造解码失败。
            payload = .unknown(type: type)
        }
    }
}

private struct SurfaceOpDTO: Decodable {
    var value: SurfaceOp

    private enum Keys: String, CodingKey { case op, startSeq, endSeq, start, end }

    init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            value = s == "append" ? .append : .other(s)
            return
        }
        let c = try decoder.container(keyedBy: Keys.self)
        let op = try c.decode(String.self, forKey: .op)
        guard op == "replace" else {
            value = .other(op)
            return
        }
        let start = try c.decodeIfPresent(Double.self, forKey: .startSeq) ?? c.decode(Double.self, forKey: .start)
        let end = try c.decodeIfPresent(Double.self, forKey: .endSeq) ?? c.decode(Double.self, forKey: .end)
        value = .replace(startSeq: start, endSeq: end)
    }
}

/// 压缩 run 的线上形式。三种 run 共用：`tool-call-chunks` 的分片字段叫 `args`，其余叫 `texts`。
private struct RunDTO: Decodable {
    var type: String?
    var index: Int
    var time0: Int64?
    var dt: [Int]?
    var texts: [String]?
    var args: [String]?
    var id: String?
    var name: String?

    var pieces: [String] { texts ?? args ?? [] }

    func streamItem(kind: String, fallbackTime0: Int64) -> StreamItem {
        let run = ChunkRun(index: index, time0: time0 ?? fallbackTime0, dt: dt ?? [], texts: pieces)
        switch kind {
        case "reasoning-chunks": return StreamItem(run: .reasoning(run))
        case "text-chunks": return StreamItem(run: .text(run))
        default: return StreamItem(run: .toolCall(run), toolCallId: id, toolName: name)
        }
    }
}

/// v3/v4 `data.stream[]` 的一项：要么是压缩 run，要么是 `{type:"chunk", time, chunk:{…}}` 控制分片。
private struct StreamEntryDTO: Decodable {
    var item: StreamItem

    private enum Keys: String, CodingKey { case type, time, chunk }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "reasoning-chunks", "text-chunks", "tool-call-chunks":
            item = try RunDTO(from: decoder).streamItem(kind: type, fallbackTime0: 0)
        case "chunk":
            let time = try c.decodeIfPresent(Int64.self, forKey: .time) ?? 0
            item = try c.decode(ChunkDTO.self, forKey: .chunk).streamItem(time: time)
        default:
            // 新的流项类型降级成控制分片：保留名字，不丢后面的内容。
            let time = try c.decodeIfPresent(Int64.self, forKey: .time) ?? 0
            item = StreamItem(run: .control(ControlChunk(time: time, kind: type, index: nil, blockType: nil)))
        }
    }
}

/// 单个未压缩分片。v4 的控制分片和 v0 的 `assistant/chunk` 共用这个结构。
private struct ChunkDTO: Decodable {
    var type: String
    var index: Int?
    var blockType: String?
    var text: String?
    var argumentsDelta: String?
    var id: String?
    var name: String?

    func streamItem(time: Int64) -> StreamItem {
        // v0 里还有未压缩的 delta（实测 reasoning-delta 12,908 条）。把它当成只有一个分片的
        // run，下游就只需要处理一种内容形态；dt 为空正好满足 dt.count == texts.count - 1。
        func single(_ s: String) -> ChunkRun { ChunkRun(index: index ?? 0, time0: time, dt: [], texts: [s]) }
        switch type {
        case "reasoning-delta": return StreamItem(run: .reasoning(single(text ?? "")))
        case "text-delta": return StreamItem(run: .text(single(text ?? "")))
        case "tool-call-delta":
            return StreamItem(run: .toolCall(single(argumentsDelta ?? "")), toolCallId: id, toolName: name)
        default:
            return StreamItem(run: .control(ControlChunk(time: time, kind: type, index: index, blockType: blockType)))
        }
    }
}

private struct LegacyChunkDTO: Decodable {
    var chunk: ChunkDTO
}

private struct SourceDTO: Decodable {
    var kind: String?
    var callId: String?
    var model: String?
    var compactionId: String?
}

private struct ContentBlockDTO: Decodable {
    var block: ContentBlock

    private enum Keys: String, CodingKey { case type, text, id, name, arguments }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "text": block = .text(try c.decodeIfPresent(String.self, forKey: .text) ?? "")
        case "reasoning": block = .reasoning(try c.decodeIfPresent(String.self, forKey: .text) ?? "")
        case "tool-call":
            block = .toolCall(
                id: try c.decode(String.self, forKey: .id),
                name: try c.decodeIfPresent(String.self, forKey: .name) ?? "",
                arguments: try c.decodeIfPresent(String.self, forKey: .arguments) ?? "")
        default: block = .other(type: type)
        }
    }
}

private struct AssistantMessageDTO: Decodable {
    struct Message: Decodable {
        var content: [ContentBlockDTO]?
        var source: SourceDTO?
    }
    var turn: Int?
    var step: Int?
    var message: Message?
    var stream: [StreamEntryDTO]?
    var usage: TokenUsage?
}

private struct ToolCallDTO: Decodable {
    var turn: Int?
    var step: Int?
    var callId: String
    var name: String
    var arguments: String
}

/// tool/result 的内容块。v4 直接是 `text`/`image`；v0/v3 套了一层 `tool-result`，
/// 真正的文本在它的 `content[]` 里。
private struct ResultBlockDTO: Decodable {
    var type: String
    var text: String?
    var toolCallId: String?
    var isError: Bool?
    var content: [ResultBlockDTO]?
}

private struct ToolResultDTO: Decodable {
    struct Message: Decodable {
        var toolCallId: String?
        var source: SourceDTO?
        var content: [ResultBlockDTO]?
        var isError: Bool?
    }
    var turn: Int?
    var step: Int?
    var message: Message

    var event: ToolResultEvent {
        let blocks = message.content ?? []
        let nested = blocks.first { $0.type == "tool-result" }
        let (callId, origin): (String?, ToolResultEvent.CallIdOrigin) = {
            if let id = message.toolCallId { return (id, .messageToolCallId) }
            if let id = message.source?.callId { return (id, .sourceCallId) }
            if let id = nested?.toolCallId { return (id, .resultBlock) }
            return (nil, .missing)
        }()
        let flat = blocks.flatMap { $0.type == "tool-result" ? ($0.content ?? []) : [$0] }
        return ToolResultEvent(
            turn: turn,
            step: step,
            callId: callId,
            callIdOrigin: origin,
            text: flat.compactMap { $0.type == "text" ? $0.text : nil }.joined(),
            isError: message.isError ?? nested?.isError ?? false,
            imageCount: flat.filter { $0.type == "image" }.count
        )
    }
}

/// user/message 的 data 本身就是消息；system/developer 的消息在 `data.message` 里。两种都接受。
private struct MessageEnvelopeDTO: Decodable {
    struct Body: Decodable {
        var role: String?
        var source: SourceDTO?
        var content: [ResultBlockDTO]?
    }
    var message: ConversationMessage

    private enum Keys: String, CodingKey { case message }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let body = try c.decodeIfPresent(Body.self, forKey: .message) ?? Body(from: decoder)
        message = ConversationMessage(
            role: body.role,
            sourceKind: body.source?.kind,
            compactionId: body.source?.compactionId,
            text: (body.content ?? []).compactMap { $0.type == "text" ? $0.text : nil }.joined()
        )
    }
}

private struct TurnDTO: Decodable {
    struct Reason: Decodable { var kind: String? }
    var turn: Int
    var reason: Reason?
}

private struct StepDTO: Decodable {
    var turn: Int
    var step: Int
}
