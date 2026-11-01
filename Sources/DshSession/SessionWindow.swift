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

    /// 求一次 `surfaceOp.replace` 在**模型上下文**里遮蔽了哪些记录。
    ///
    /// **这个方法不删除任何东西**，而且这是刻意的。`replace` 改写的是模型看到的
    /// 上下文（surface），不是给人看的对话记录。host 的 web 客户端
    /// （`dsh-client-ui-chat`，`isAppendSurfaceEvent` 的注释）把这一点写得很直白：
    ///
    /// > 面向模型的 surface 会刻意遮蔽被替换的范围，所以它不能拿来当人类可读的
    /// > 对话记录——一次替换落地，就会抹掉用户已经看过的对话。append 来源的事件
    /// > 才是对话记录的持久素材；替换出来的副本只给模型看。
    ///
    /// 早期版本按"先删区间、再插新记录"实现，回放真实会话时暴露出后果：
    /// `compact-checkpoint` 的替换区间最宽跨 **1,298 个 seq**，压缩一次就会把
    /// 用户看过的整段历史从界面上抹掉。
    ///
    /// 所以窗口只回答"哪些被遮蔽了"，供轨迹视图标注或统计用；正文照常显示它们。
    ///
    /// - Returns: 闭区间 `[startSeq, endSeq]` 内的记录 seq。
    public func shadowed(startSeq: EventSeq, endSeq: EventSeq) -> [EventSeq] {
        records
            .filter { $0.seq >= startSeq && $0.seq <= endSeq }
            .map(\.seq)
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
