import XCTest
@testable import DshPresenter
@testable import DshSession

/// 轮次与步骤骨架。
///
/// 这一层的错误症状是"某段内容从界面上消失了"——节点归属不到轮次就不会被渲染，
/// 而且不报错。所以乱序、重复、窗口从中间开始这几种情况都要测。
final class TurnStructureTests: XCTestCase {

    // MARK: - 基本结构

    func testTurnOpensAndCloses() {
        var structure = TurnStructure()
        structure.startTurn(index: 1, seq: 10)
        XCTAssertTrue(structure.hasOpenTurn)
        XCTAssertFalse(structure.turns[0].isClosed)

        structure.endTurn(index: 1, seq: 50, reason: .completed)
        XCTAssertFalse(structure.hasOpenTurn)
        XCTAssertTrue(structure.turns[0].isClosed)
        XCTAssertEqual(structure.turns[0].reason, .completed)
    }

    func testStepsAttachToTurn() {
        var structure = TurnStructure()
        structure.startTurn(index: 1, seq: 10)
        structure.startStep(turn: 1, step: 1, seq: 11)
        structure.startStep(turn: 1, step: 2, seq: 20)
        structure.endStep(turn: 1, step: 1, seq: 19)

        XCTAssertEqual(structure.turns[0].steps.map(\.index), [1, 2])
        XCTAssertTrue(structure.turns[0].steps[0].isClosed)
        XCTAssertFalse(structure.turns[0].steps[1].isClosed)
    }

    func testTurnsSortByIndex() {
        var structure = TurnStructure()
        structure.startTurn(index: 3, seq: 100)
        structure.startTurn(index: 1, seq: 10)
        structure.startTurn(index: 2, seq: 50)
        XCTAssertEqual(structure.turns.map(\.index), [1, 2, 3])
    }

    // MARK: - 幂等

    /// 重连后 snapshot 与增量会重叠，同一条 `turn/start` 会到两次。
    /// 不能因此新建第二个轮次。
    func testDuplicateTurnStartIsIdempotent() {
        var structure = TurnStructure()
        structure.startTurn(index: 1, seq: 10)
        structure.startTurn(index: 1, seq: 10)
        XCTAssertEqual(structure.turns.count, 1)
    }

    func testDuplicateStepStartIsIdempotent() {
        var structure = TurnStructure()
        structure.startTurn(index: 1, seq: 10)
        structure.startStep(turn: 1, step: 1, seq: 11)
        structure.startStep(turn: 1, step: 1, seq: 11)
        XCTAssertEqual(structure.turns[0].steps.count, 1)
    }

    // MARK: - 乱序与缺失

    /// 窗口从轮次中间开始（分页取历史时很常见）：先见到 `step/start`，
    /// 没见过对应的 `turn/start`。
    ///
    /// 必须补一个轮次，否则这个 step 的节点无处归属，整段内容从界面上消失。
    func testStepWithoutTurnCreatesTurn() {
        var structure = TurnStructure()
        structure.startStep(turn: 7, step: 3, seq: 500)

        XCTAssertEqual(structure.turns.count, 1)
        XCTAssertEqual(structure.turns[0].index, 7)
        XCTAssertEqual(structure.turns[0].startSeq, 500, "补出来的轮次用 step 的 seq 当起点")
        XCTAssertEqual(structure.turns[0].steps.map(\.index), [3])
    }

    /// 补出轮次后，真正的 `turn/start` 到了也不该重建。
    func testLateTurnStartDoesNotDuplicate() {
        var structure = TurnStructure()
        structure.startStep(turn: 7, step: 3, seq: 500)
        structure.startTurn(index: 7, seq: 400)
        XCTAssertEqual(structure.turns.count, 1)
    }

    /// 不认识的轮次的 end 要忽略，不能崩也不能凭空造一个已结束的轮次。
    func testEndOfUnknownTurnIsIgnored() {
        var structure = TurnStructure()
        structure.endTurn(index: 9, seq: 100, reason: .completed)
        XCTAssertTrue(structure.turns.isEmpty)
    }

    func testEndOfUnknownStepIsIgnored() {
        var structure = TurnStructure()
        structure.startTurn(index: 1, seq: 10)
        structure.endStep(turn: 1, step: 5, seq: 20)
        XCTAssertTrue(structure.turns[0].steps.isEmpty)
    }

    // MARK: - seq 归属

    func testSeqMapsToContainingTurn() {
        var structure = TurnStructure()
        structure.startTurn(index: 1, seq: 10)
        structure.endTurn(index: 1, seq: 50, reason: .completed)
        structure.startTurn(index: 2, seq: 60)
        structure.endTurn(index: 2, seq: 99, reason: .completed)

        XCTAssertEqual(structure.turn(containing: 10)?.index, 1)
        XCTAssertEqual(structure.turn(containing: 30)?.index, 1)
        XCTAssertEqual(structure.turn(containing: 50)?.index, 1, "边界包含在内")
        XCTAssertEqual(structure.turn(containing: 60)?.index, 2)
        XCTAssertEqual(structure.turn(containing: 99)?.index, 2)
    }

    /// 进行中的轮次吃掉它起点之后的一切——包括还没落盘的实时事件。
    func testOpenTurnClaimsEverythingAfterStart() {
        var structure = TurnStructure()
        structure.startTurn(index: 1, seq: 10)
        structure.endTurn(index: 1, seq: 50, reason: .completed)
        structure.startTurn(index: 2, seq: 60)

        XCTAssertEqual(structure.turn(containing: 999)?.index, 2)
        XCTAssertEqual(structure.turn(containing: 60.5)?.index, 2, "小数 seq 的实时事件")
    }

    /// 落在两轮之间的 seq（轮次结束后、下一轮开始前）不属于任何轮次。
    func testSeqBetweenTurnsBelongsToNoTurn() {
        var structure = TurnStructure()
        structure.startTurn(index: 1, seq: 10)
        structure.endTurn(index: 1, seq: 50, reason: .completed)
        structure.startTurn(index: 2, seq: 60)
        structure.endTurn(index: 2, seq: 99, reason: .completed)

        XCTAssertNil(structure.turn(containing: 55))
    }

    func testSeqBeforeFirstTurnBelongsToNoTurn() {
        var structure = TurnStructure()
        structure.startTurn(index: 1, seq: 10)
        XCTAssertNil(structure.turn(containing: 5))
    }

    // MARK: - 结束原因

    /// 五种原因全部来自实测。非 completed 的占 19.4%，所以每种都要能显示。
    func testAllMeasuredReasonsParse() {
        XCTAssertEqual(TurnEndReason(kind: "completed", detail: nil), .completed)
        XCTAssertEqual(TurnEndReason(kind: "interrupted", detail: nil), .interrupted)
        XCTAssertEqual(TurnEndReason(kind: "max-tokens", detail: nil), .maxTokens)
        XCTAssertEqual(
            TurnEndReason(kind: "aborted", detail: "user cancelled"),
            .aborted("user cancelled")
        )
        XCTAssertEqual(
            TurnEndReason(kind: "error", detail: "rate limited"),
            .error("rate limited")
        )
    }

    /// 没见过的原因不猜，原样保留——上游随时可能加新的。
    func testUnknownReasonPreservesKind() {
        XCTAssertEqual(
            TurnEndReason(kind: "something-new", detail: nil),
            .unknown("something-new")
        )
    }

    /// 只有 completed 算干净结束。其余都要在轮次尾给提示。
    func testOnlyCompletedIsClean() {
        XCTAssertTrue(TurnEndReason.completed.isClean)
        XCTAssertFalse(TurnEndReason.interrupted.isClean)
        XCTAssertFalse(TurnEndReason.maxTokens.isClean)
        XCTAssertFalse(TurnEndReason.aborted(nil).isClean)
        XCTAssertFalse(TurnEndReason.error(nil).isClean)
        XCTAssertFalse(TurnEndReason.unknown("x").isClean)
    }

    // MARK: - 规模

    /// p99 的轮次有 236 个 step，max 401。结构本身要能承受。
    func testManyStepsInOneTurn() {
        var structure = TurnStructure()
        structure.startTurn(index: 1, seq: 0)
        for step in 1...401 {
            structure.startStep(turn: 1, step: step, seq: EventSeq(step))
        }
        XCTAssertEqual(structure.turns[0].steps.count, 401)
        XCTAssertEqual(structure.turns[0].steps.last?.index, 401)
    }
}
