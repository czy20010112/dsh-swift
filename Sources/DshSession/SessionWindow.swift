import DshProtocol

/// 会话事件的序号。
///
/// **必须是 Double，不能是 Int**：实时增量是"合成事件"，带小数 seq
/// （host 侧算法是 `durableCursor + 1 - 1/(n+1)`），靠小数把 live chunk 插在
/// 已落盘事件之间。用 Int 排序会让实时内容全部塌到同一个位置。
public typealias EventSeq = Double

/// 一条会话记录在窗口里的位置。
public struct WindowedRecord: Sendable, Equatable {
    public var seq: EventSeq
    /// 事件类型，形如 `tool/call`。未知类型也要保留——它可能被 surfaceOp 引用。
    public var type: String
    /// 是否是实时合成事件。耐久事件到达后要把它挤出去。
    public var isLive: Bool

    public init(seq: EventSeq, type: String, isLive: Bool) {
        self.seq = seq
        self.type = type
        self.isLive = isLive
    }
}

/// 会话窗口：按 seq 有序的记录集合，支持增量 apply 与历史重写。
///
/// 这一层只管"窗口里有哪些记录、顺序如何"，不管它们渲染成什么——那是 DshPresenter 的事。
public struct SessionWindow: Sendable {

    public private(set) var records: [WindowedRecord] = []

    public init() {}

    public init(records: [WindowedRecord]) {
        self.records = records.sorted { $0.seq < $1.seq }
    }

    /// 插入或替换一条记录（按 seq 定位）。
    public mutating func upsert(_ record: WindowedRecord) {
        if let index = records.firstIndex(where: { $0.seq == record.seq }) {
            records[index] = record
        } else {
            let insertAt = records.firstIndex { $0.seq > record.seq } ?? records.count
            records.insert(record, at: insertAt)
        }
    }

    /// 处理 `surfaceOp: {op:"replace", startSeq, endSeq}`。
    ///
    /// 语义是**先删后插**：摘掉 `[startSeq, endSeq]` 闭区间里的旧记录，再插入新记录。
    /// 顺序颠倒（先插后删）会把刚插进去的那条自己删掉，或者留下重复节点。
    ///
    /// 实测这个 op 在 326 个会话里出现 152 次，是"重写更早消息"路径的唯一机制。
    /// 它的症状很隐蔽：同一条回复出现两次，或者显示旧版内容——都不报错，
    /// 所以这里必须有测试。
    public mutating func replace(
        startSeq: EventSeq,
        endSeq: EventSeq,
        with record: WindowedRecord
    ) {
        records.removeAll { $0.seq >= startSeq && $0.seq <= endSeq }
        let insertAt = records.firstIndex { $0.seq > record.seq } ?? records.count
        records.insert(record, at: insertAt)
    }

    /// 耐久事件到达，把同位置的实时合成事件退役。
    ///
    /// live chunk 的 seq 是 `durableCursor + 1 - 1/(n+1)`，永远落在
    /// `(durableCursor, durableCursor+1)` 这个开区间里。所以耐久事件 seq = N 到达时，
    /// 要清掉 `(N-1, N)` 区间内的所有 live 记录。
    public mutating func retireLiveChunks(upTo durableSeq: EventSeq) {
        records.removeAll { $0.isLive && $0.seq < durableSeq && $0.seq > durableSeq - 1 }
    }

    /// 窗口里最大的耐久 seq，用于判断是否出现断档。
    public var durableCursor: EventSeq? {
        records.last { !$0.isLive }?.seq
    }
}
