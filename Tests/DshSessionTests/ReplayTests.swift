import Foundation
import XCTest
@testable import DshSession

/// 用真实会话（脱敏后）回放解码器和窗口。
///
/// 手写夹具只能验证"我们以为的格式"。这套夹具由 `Tools/export-fixtures.mjs` 从本机
/// 真实会话里按事件类型覆盖度挑出，三代格式都有，专门用来抓手写夹具抓不到的东西。
///
/// 夹具路径用 `#filePath` 推算而不走 `Bundle.module`：后者要在 Package.swift 里给测试 target
/// 声明资源，而夹具是导出脚本整目录重写的，不属于任何 target。
final class ReplayTests: XCTestCase {

    // MARK: - 夹具加载

    private struct Fixture: Decodable {
        var name: String
        var generation: String
        var header: SessionHeader
        var events: [LossyDecoded<SessionEvent>]
    }

    private struct Manifest: Decodable {
        struct Entry: Decodable {
            var file: String
            var generation: String
            var eventCount: Int
            var types: [String: Int]
            var orphanToolResults: Int
            /// 是否整段导出。抽样导出的夹具 seq 有人为断档。
            var complete: Bool
        }
        var fixtures: [Entry]
    }

    private static let fixturesDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")

    private static func loadManifest() throws -> Manifest {
        let data = try Data(contentsOf: fixturesDir.appendingPathComponent("manifest.json"))
        return try JSONDecoder().decode(Manifest.self, from: data)
    }

    private struct Loaded {
        var entry: Manifest.Entry
        var fixture: Fixture
        var events: [SessionEvent]
        var failures: [EventDecodingFailure]
    }

    /// 只加载一次：16 个夹具共约 1.6 MB，每个测试都重读会让测试慢一截。
    private static let loaded: Result<[Loaded], Error> = Result {
        try loadManifest().fixtures.map { entry in
            let data = try Data(contentsOf: fixturesDir.appendingPathComponent(entry.file))
            let fixture = try JSONDecoder().decode(Fixture.self, from: data)
            return Loaded(
                entry: entry,
                fixture: fixture,
                events: fixture.events.compactMap(\.value),
                failures: fixture.events.compactMap(\.failure)
            )
        }
    }

    private func fixtures() throws -> [Loaded] {
        let all = try Self.loaded.get()
        XCTAssertFalse(all.isEmpty, "manifest 里没有夹具；先跑 node Tools/export-fixtures.mjs")
        return all
    }

    // MARK: - 解码

    func testEveryEventDecodes() throws {
        for f in try fixtures() {
            XCTAssertEqual(f.events.count, f.entry.eventCount, "\(f.entry.file): 事件数与 manifest 不符")
            XCTAssertTrue(
                f.failures.isEmpty,
                "\(f.entry.file): \(f.failures.count) 条解码失败，首条 \(String(describing: f.failures.first))"
            )
        }
    }

    /// header 里的版本号必须和导出时认定的代际一致：解码器靠它决定去哪里找流分片和配对 id。
    func testHeaderGenerationMatchesManifest() throws {
        for f in try fixtures() {
            let expected: SessionGeneration
            switch f.entry.generation {
            case "v0": expected = .v0
            case "v3": expected = .v3
            case "v4": expected = .v4
            default: expected = .future(-1)
            }
            XCTAssertEqual(f.fixture.header.generation, expected, f.entry.file)
        }
    }

    /// 解码出的类型分布与导出脚本统计的一致。两边用不同语言各数一遍，任何一边漏读事件都会暴露。
    func testTypeDistributionMatchesManifest() throws {
        for f in try fixtures() {
            var counts: [String: Int] = [:]
            for e in f.events { counts[e.type, default: 0] += 1 }
            XCTAssertEqual(counts, f.entry.types, f.entry.file)

            let modeled = f.events.filter { if case .unknown = $0.payload { return false } else { return true } }.count
            let lines = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .map { "    \($0.value)\t\($0.key)" }
            print("""
                [replay] \(f.entry.file) (\(f.entry.generation)): \(f.events.count) 个事件，\
                \(counts.count) 种类型，\(modeled) 个已建模 / \(f.events.count - modeled) 个降级为 unknown
                \(lines.joined(separator: "\n"))
                """)
        }
    }

    // MARK: - seq 顺序

    /// 落盘事件按文件顺序 seq 严格递增，且 v0 的 run 行不与下一条重叠。
    ///
    /// v0 的 run 占 `seq0 ..< seq0 + n`。只检查 `seq[i] > seq[i-1]` 会放过"下一条落在 run 中间"
    /// 这种错误，而那正是把 run 当成单个 seq 时会出现的。
    func testSeqStrictlyIncreasingWithoutOverlap() throws {
        for f in try fixtures() {
            var previous: SessionEvent?
            for e in f.events {
                if let p = previous {
                    XCTAssertGreaterThan(e.seq, p.seq, "\(f.entry.file): seq \(e.seq) (\(e.type)) 不大于前一条 \(p.seq)")
                    XCTAssertGreaterThanOrEqual(
                        e.seq, p.seq + Double(p.seqSpan),
                        "\(f.entry.file): seq \(e.seq) 落在前一条 run [\(p.seq), \(p.seq + Double(p.seqSpan))) 内")
                }
                previous = e
            }
        }
    }

    /// 在真实事件之间插入 live 合成分片，检查它们排在正确的位置。
    ///
    /// 落盘日志里没有 live 分片（它们只存在于实时连接中），所以用 host 的算法
    /// `durableCursor + 1 - 1/(n+1)` 现场合成，再交给窗口排序。
    func testLiveChunksSortBetweenDurableEvents() throws {
        for f in try fixtures() {
            let durable = f.events.map(\.windowedRecord)
            guard durable.count >= 2 else { continue }
            var window = SessionWindow()
            var expected: [EventSeq] = []
            for (i, record) in durable.enumerated() {
                window.upsert(record)
                expected.append(record.seq)
                // 每隔几条插一组 live，覆盖开头、中间和末尾
                guard i % 7 == 0 || i == durable.count - 1 else { continue }
                for n in 1...3 {
                    let liveSeq = record.seq + 1 - 1 / Double(n + 1)
                    // 只在下一条落盘事件之前插：v0 run 后面紧跟的 seq 可能正好是 cursor+1
                    if i + 1 < durable.count, liveSeq >= durable[i + 1].seq { continue }
                    window.upsert(WindowedRecord(seq: liveSeq, type: "assistant/chunk", isLive: true))
                    expected.append(liveSeq)
                }
            }
            XCTAssertEqual(window.records.map(\.seq), expected, "\(f.entry.file): live 分片位置错误")
            XCTAssertEqual(window.durableCursor, durable.last?.seq, f.entry.file)
        }
    }

    /// 按真实到达顺序回放：每个落盘事件到达前先退役它前面的 live 分片。
    ///
    /// `retireLiveChunks(upTo: N)` 只清 `(N-1, N)`，前提是下一条落盘 seq 正好是 cursor+1。
    /// 真实日志里这个前提不总成立（v0 的 run 一行占 n 个 seq；v3 文件里有 seq 断档），
    /// 断档处的 live 分片会滞留。这里把滞留数统计出来——它不是窗口的 bug 就是协议的约定，
    /// 要由读 host 源码来定，所以只报告不判失败。
    func testLiveChunkRetirementAcrossRealSeqGaps() throws {
        var stranded: [String: Int] = [:]
        // 抽样导出的夹具里，断档是导出脚本删事件造成的，不代表真实数据，只看完整导出的。
        for f in try fixtures() where f.entry.complete {
            var window = SessionWindow()
            for e in f.events {
                window.retireLiveChunks(upTo: e.seq)
                let leftovers = window.records.filter { $0.isLive && $0.seq < e.seq }
                if !leftovers.isEmpty { stranded[f.entry.file, default: 0] += leftovers.count }
                // 滞留的分片在真实客户端里会一直显示；这里清掉，免得一处断档污染后面的计数
                window = SessionWindow(records: window.records.filter { !$0.isLive || $0.seq > e.seq })
                window.upsert(e.windowedRecord)
                // cursor 取 run 的最后一个 seq：v0 的 run 占 seq0 ..< seq0+span
                let cursor = e.seq + Double(e.seqSpan - 1)
                for n in 1...2 {
                    window.upsert(WindowedRecord(seq: cursor + 1 - 1 / Double(n + 1), type: "assistant/chunk", isLive: true))
                }
            }
            if let last = f.events.last {
                window.retireLiveChunks(upTo: last.seq + Double(last.seqSpan))
                XCTAssertFalse(window.records.contains { $0.isLive }, "\(f.entry.file): 末尾 live 分片没有退役")
            }
        }
        print("[replay] 因 seq 断档而滞留的 live 分片: \(stranded.isEmpty ? "无" : "\(stranded.sorted { $0.key < $1.key })")")
    }

    // MARK: - 压缩流

    func testChunkRunDtIsOneShorterThanTexts() throws {
        var runs = 0
        var negative = 0
        for f in try fixtures() {
            for e in f.events {
                for item in e.streamItems {
                    let run: ChunkRun
                    switch item.run {
                    case .text(let r), .reasoning(let r), .toolCall(let r): run = r
                    case .control: continue
                    }
                    runs += 1
                    negative += run.dt.filter { $0 < 0 }.count
                    XCTAssertTrue(
                        run.texts.isEmpty || run.dt.count == run.texts.count - 1,
                        "\(f.entry.file) seq \(e.seq): texts=\(run.texts.count) dt=\(run.dt.count)")
                    XCTAssertEqual(AssistantStream.expand(run).count, run.texts.count)
                }
            }
        }
        XCTAssertGreaterThan(runs, 0, "夹具里一条 run 都没解出来，流分片解码大概率坏了")
        print("[replay] 共检查 \(runs) 条 run，其中负 dt \(negative) 个")
    }

    /// 两代流分片的位置不同：v0 是顶层行，v3/v4 嵌在 assistant/message 里。
    /// 认错代际的症状是"思考和正文全部消失"，不会报错。
    func testStreamLocationMatchesGeneration() throws {
        for f in try fixtures() {
            let topLevel = f.events.filter { if case .stream = $0.payload { return true } else { return false } }.count
            let embedded = f.events.reduce(0) { acc, e in
                if case .assistantMessage(let m) = e.payload { return acc + m.stream.count }
                return acc
            }
            switch f.fixture.header.generation {
            case .v0:
                XCTAssertEqual(embedded, 0, "\(f.entry.file): v0 不应有内嵌 stream")
            case .v3, .v4, .future:
                XCTAssertEqual(topLevel, 0, "\(f.entry.file): v3/v4 不应有顶层流分片")
            }
        }
    }

    // MARK: - 工具配对

    /// 每个 tool/result 按 callId 找对应的 tool/call。
    ///
    /// 配不上的不算失败，统计出来并与导出脚本的独立统计对拍：这是数据本身的性质，
    /// 装配器必须能容忍，而不是假设它不存在。
    func testToolResultsPairWithCalls() throws {
        var totalResults = 0
        var totalOrphans = 0
        for f in try fixtures() {
            var callIds = Set<String>()
            var orphans: [(EventSeq, String?)] = []
            var results = 0
            for e in f.events {
                switch e.payload {
                case .toolCall(let call):
                    callIds.insert(call.callId)
                case .toolResult(let result):
                    results += 1
                    XCTAssertNotNil(result.callId, "\(f.entry.file) seq \(e.seq): tool/result 没有任何配对 id")
                    // v4 才有 message.toolCallId；v0/v3 必须走 source.callId，否则全部配不上
                    switch f.fixture.header.generation {
                    case .v4: XCTAssertEqual(result.callIdOrigin, .messageToolCallId, f.entry.file)
                    case .v0, .v3: XCTAssertEqual(result.callIdOrigin, .sourceCallId, f.entry.file)
                    case .future: break
                    }
                    if let id = result.callId, !callIds.contains(id) {
                        orphans.append((e.seq, id))
                    }
                default:
                    break
                }
            }
            XCTAssertEqual(orphans.count, f.entry.orphanToolResults, "\(f.entry.file): 孤儿 tool/result 数与导出脚本不一致")
            if !orphans.isEmpty {
                print("[replay] \(f.entry.file): \(orphans.count)/\(results) 个 tool/result 找不到 tool/call，seq = \(orphans.map(\.0))")
            }
            totalResults += results
            totalOrphans += orphans.count
        }
        print("[replay] tool/result 共 \(totalResults) 个，配不上 \(totalOrphans) 个")
    }

    // MARK: - 降级

    /// 夹具里所有类型都是已知的，所以单独验证降级路径：未知类型、小数 seq、坏行都不能拖垮整份日志。
    func testJSONLDegradesInsteadOfThrowing() {
        let jsonl = """
            {"type":"session","version":4,"id":"s","cwd":"/workspace"}
            {"type":"turn/start","seq":1,"time":10,"data":{"turn":1}}
            {"type":"some-plugin/new-thing","seq":1.5,"time":11,"data":{"whatever":[1,{"x":null}]}}
            {"type":"tool/call","seq":2,"time":12,"data":{"callId":"c1","name":"read"}}
            {"type":"turn/end","seq":3,"tim
            """
        let log = EventDecoder.decodeJSONL(jsonl)
        XCTAssertEqual(log.header?.generation, .v4)
        XCTAssertEqual(log.events.map(\.seq), [1, 1.5])
        XCTAssertEqual(log.events.last?.payload, .unknown(type: "some-plugin/new-thing"))
        // tool/call 缺 arguments 是结构错误，必须记成失败并带上能定位的 type/seq
        XCTAssertEqual(log.failures.count, 2)
        XCTAssertEqual(log.failures.first?.type, "tool/call")
        XCTAssertEqual(log.failures.first?.seq, 2)
    }

    // MARK: - surfaceOp

    /// replace 的区间两代键名不同（v0: start/end，v3/v4: startSeq/endSeq），解码后必须都是 `.replace`。
    func testReplaceSurfaceOpsDecodeInEveryGeneration() throws {
        var replaces: [String: Int] = [:]
        for f in try fixtures() {
            for e in f.events {
                guard let op = e.surfaceOp else { continue }
                switch op {
                case .replace(let start, let end):
                    replaces[f.entry.generation, default: 0] += 1
                    XCTAssertLessThanOrEqual(start, end, "\(f.entry.file) seq \(e.seq)")
                    // 实测 replace 的区间总在它自己之前：它重写的是更早的消息
                    XCTAssertLessThan(end, e.seq, "\(f.entry.file) seq \(e.seq): replace 指向了未来")
                case .append:
                    break
                case .other(let name):
                    XCTFail("\(f.entry.file) seq \(e.seq): 未知 surfaceOp \(name)")
                }
            }
        }
        print("[replay] 各代 replace 数: \(replaces.sorted { $0.key < $1.key })")
    }
}
