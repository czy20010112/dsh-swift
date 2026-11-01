import XCTest
@testable import DshSession

/// surface（模型上下文）与 transcript（对话记录）的分离。
///
/// 这里出错的症状是"用户看过的内容消失了"或者"同一条内容出现两次"，
/// 都不报错。所以三种角色和每个实测来源都要测到。
final class SurfaceRoleTests: XCTestCase {

    // MARK: - append 进正文

    func testAppendEntersTranscript() {
        let role = SurfaceRole.classify(type: "assistant/message", surfaceOp: .append, sourceKind: nil)
        XCTAssertEqual(role, .transcript)
        XCTAssertTrue(role.entersTranscript)
    }

    /// 实测五种 surface 事件在 append 时都进正文。
    func testAllSurfaceTypesAppendToTranscript() {
        for type in SurfaceRole.surfaceEventTypes {
            let role = SurfaceRole.classify(type: type, surfaceOp: .append, sourceKind: "user")
            XCTAssertTrue(role.entersTranscript, "\(type) append 应该进正文")
        }
    }

    // MARK: - replace 只给模型

    /// 一个调用的第二个结果总带 replace（实测 91 次）。它是模型侧的改写副本，
    /// 进正文的话同一个工具会显示两份结果。
    func testReplacedToolResultIsModelOnly() {
        let role = SurfaceRole.classify(
            type: "tool/result", surfaceOp: .replace(startSeq: 40, endSeq: 40), sourceKind: nil
        )
        XCTAssertEqual(role, .modelOnly(shadows: 40...40))
        XCTAssertFalse(role.entersTranscript)
    }

    /// system/message 的 replace（实测 22 次）同样不进正文。
    func testReplacedSystemMessageIsModelOnly() {
        let role = SurfaceRole.classify(
            type: "system/message", surfaceOp: .replace(startSeq: 3, endSeq: 3), sourceKind: nil
        )
        XCTAssertFalse(role.entersTranscript)
    }

    /// plugin 来源的 user/message replace（实测 6 次）不是检查点，按普通替换处理。
    func testPluginReplaceIsModelOnlyNotCheckpoint() {
        let role = SurfaceRole.classify(
            type: "user/message", surfaceOp: .replace(startSeq: 5, endSeq: 90), sourceKind: "plugin"
        )
        XCTAssertEqual(role, .modelOnly(shadows: 5...90))
    }

    // MARK: - 压缩检查点

    /// 实测 35 次。不显示它的内容（那是写给模型的摘要），但要识别出来，
    /// 好在它的位置放"上下文已压缩"的标记。
    func testCompactCheckpointIsRecognized() {
        let role = SurfaceRole.classify(
            type: "user/message",
            surfaceOp: .replace(startSeq: 10, endSeq: 1307),
            sourceKind: "compact-checkpoint",
            compactionId: "c-1"
        )
        XCTAssertEqual(role, .compactionCheckpoint(compactionId: "c-1", shadows: 10...1307))
        XCTAssertFalse(role.entersTranscript, "检查点的内容是写给模型的摘要，不进正文")
    }

    /// `compact-checkpoint` 只在 replace 时才是检查点。append 的同名来源按普通消息走
    /// （然后由用户行白名单把它挡掉，它不是真人发言）。
    func testCompactCheckpointKindWithAppendIsTranscript() {
        let role = SurfaceRole.classify(
            type: "user/message", surfaceOp: .append, sourceKind: "compact-checkpoint"
        )
        XCTAssertEqual(role, .transcript)
    }

    // MARK: - 非 surface 事件

    func testNonSurfaceEventsAreUnaffected() {
        for type in ["tool/call", "turn/start", "reasoning-chunks", "compaction/summary"] {
            let role = SurfaceRole.classify(
                type: type, surfaceOp: .replace(startSeq: 1, endSeq: 9), sourceKind: nil
            )
            XCTAssertEqual(role, .notSurface, "\(type) 不是 surface 事件")
            XCTAssertTrue(role.entersTranscript)
        }
    }

    // MARK: - 降级

    /// 没见过的 op 按 append：宁可多显示一条，也不要让内容消失。
    func testUnknownOpFallsBackToTranscript() {
        let role = SurfaceRole.classify(
            type: "assistant/message", surfaceOp: .other("splice"), sourceKind: nil
        )
        XCTAssertEqual(role, .transcript)
    }

    func testMissingOpFallsBackToTranscript() {
        let role = SurfaceRole.classify(type: "assistant/message", surfaceOp: nil, sourceKind: nil)
        XCTAssertEqual(role, .transcript)
    }

    /// 端点颠倒的区间不能算出一个反向范围（ClosedRange 会直接崩）。
    func testInvertedRangeDoesNotTrap() {
        let role = SurfaceRole.classify(
            type: "tool/result", surfaceOp: .replace(startSeq: 50, endSeq: 10), sourceKind: nil
        )
        XCTAssertEqual(role, .modelOnly(shadows: 50...50))
    }

    // MARK: - 与解码器衔接

    func testSessionEventExposesRole() {
        let event = SessionEvent(
            seq: 1315,
            time: 0,
            type: "user/message",
            surfaceOp: .replace(startSeq: 10, endSeq: 1312),
            sourceEventSeqs: [],
            payload: .message(ConversationMessage(
                role: "user",
                sourceKind: "compact-checkpoint",
                compactionId: "647d",
                text: "# 检查点"
            ))
        )
        XCTAssertEqual(event.surfaceRole, .compactionCheckpoint(compactionId: "647d", shadows: 10...1312))
    }
}
