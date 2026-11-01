import XCTest
@testable import DshProtocol

/// 待决交互的状态机。
///
/// 这条路径上有三个并发来源会任意交错——用户点按钮、host 发 cancel、连接断代——
/// 每一种组合都试过一遍，因为出错的症状是"点了没反应"或"卡片消失但没答复"，
/// 都不会报错。
final class InteractionSlotTests: XCTestCase {

    private func approval(_ id: String, command: String = "git push") -> PendingInteraction {
        PendingInteraction(
            id: id,
            agentId: "agent-1",
            kind: .approval(command: command),
            receivedAt: Date(timeIntervalSince1970: 0)
        )
    }

    // MARK: - ready 之前不能收不能答

    /// ready 之前到的 waterfall 必须丢掉：没有 clientId 就没法答复，
    /// 留着只会显示一张点了没反应的卡片。
    func testRejectsInteractionBeforeReady() {
        var slot = InteractionSlot()
        XCTAssertFalse(slot.receive(approval("e1")))
        XCTAssertNil(slot.current)
        XCTAssertFalse(slot.canAnswer)
    }

    func testCannotAnswerBeforeReady() {
        var slot = InteractionSlot()
        XCTAssertNil(slot.answer(.result))
    }

    // MARK: - 正常闭环

    func testReceiveThenAnswer() {
        var slot = InteractionSlot()
        _ = slot.beginGeneration(clientId: "c1")
        XCTAssertTrue(slot.receive(approval("e1")))
        XCTAssertTrue(slot.canAnswer)

        let payload = slot.answer(.result)
        XCTAssertEqual(payload?.clientId, "c1")
        XCTAssertEqual(payload?.eventId, "e1")
        XCTAssertEqual(payload?.outcome, .result)
        XCTAssertNil(slot.current)
    }

    /// 自己答复后 host 会回一个 cancel 帧。那是回响，不该提示用户。
    func testCancelAfterOwnAnswerIsSilent() {
        var slot = InteractionSlot()
        _ = slot.beginGeneration(clientId: "c1")
        _ = slot.receive(approval("e1"))
        _ = slot.answer(.result)

        XCTAssertNil(slot.cancel(eventId: "e1"), "自己答复的回响不该产生用户可见的结果")
    }

    /// 没答过就收到 cancel = 别的客户端先答了。
    ///
    /// 这是多设备下的预期情况：电脑浏览器和手机同时连着同一个 host，
    /// 审批会同时弹在两边，谁先点谁生效。
    func testCancelWithoutOwnAnswerMeansAnsweredElsewhere() {
        var slot = InteractionSlot()
        _ = slot.beginGeneration(clientId: "c1")
        _ = slot.receive(approval("e1"))

        XCTAssertEqual(slot.cancel(eventId: "e1"), .answeredElsewhere)
        XCTAssertNil(slot.current)
    }

    func testCancelOfUnknownIdIsIgnored() {
        var slot = InteractionSlot()
        _ = slot.beginGeneration(clientId: "c1")
        _ = slot.receive(approval("e1"))

        XCTAssertNil(slot.cancel(eventId: "nope"))
        XCTAssertEqual(slot.current?.id, "e1", "不认识的 cancel 不该动当前项")
    }

    // MARK: - 排队

    /// 同一时刻只显示一条，多出来的排队。手机屏幕上并排两张审批卡没法用。
    func testSecondInteractionQueues() {
        var slot = InteractionSlot()
        _ = slot.beginGeneration(clientId: "c1")
        _ = slot.receive(approval("e1"))
        _ = slot.receive(approval("e2"))

        XCTAssertEqual(slot.current?.id, "e1")
        XCTAssertEqual(slot.queue.map(\.id), ["e2"])
    }

    func testAnsweringAdvancesToQueued() {
        var slot = InteractionSlot()
        _ = slot.beginGeneration(clientId: "c1")
        _ = slot.receive(approval("e1"))
        _ = slot.receive(approval("e2"))

        _ = slot.answer(.result)
        XCTAssertEqual(slot.current?.id, "e2")
        XCTAssertTrue(slot.queue.isEmpty)
    }

    /// 排队中的那条被别人答了，要从队列里摘掉，不能等它轮到前台才发现已失效。
    func testCancelRemovesQueuedInteraction() {
        var slot = InteractionSlot()
        _ = slot.beginGeneration(clientId: "c1")
        _ = slot.receive(approval("e1"))
        _ = slot.receive(approval("e2"))

        XCTAssertEqual(slot.cancel(eventId: "e2"), .answeredElsewhere)
        XCTAssertEqual(slot.current?.id, "e1")
        XCTAssertTrue(slot.queue.isEmpty)
    }

    func testDuplicateIdDoesNotQueueTwice() {
        var slot = InteractionSlot()
        _ = slot.beginGeneration(clientId: "c1")
        _ = slot.receive(approval("e1"))
        _ = slot.receive(approval("e2"))
        _ = slot.receive(approval("e2"))

        XCTAssertEqual(slot.queue.map(\.id), ["e2"])
    }

    func testRepeatOfCurrentIdIsNotQueued() {
        var slot = InteractionSlot()
        _ = slot.beginGeneration(clientId: "c1")
        _ = slot.receive(approval("e1"))
        _ = slot.receive(approval("e1"))

        XCTAssertEqual(slot.current?.id, "e1")
        XCTAssertTrue(slot.queue.isEmpty)
    }

    // MARK: - 断代

    /// 重连 = 新一代，旧 clientId 作废。所有 pending 都要交还给调用方标"已失效"，
    /// **不能默默丢掉**——用户正等着那个审批。
    func testNewGenerationOrphansEverything() {
        var slot = InteractionSlot()
        _ = slot.beginGeneration(clientId: "c1")
        _ = slot.receive(approval("e1"))
        _ = slot.receive(approval("e2"))

        let orphaned = slot.beginGeneration(clientId: "c2")
        XCTAssertEqual(orphaned.map(\.id), ["e1", "e2"])
        XCTAssertNil(slot.current)
        XCTAssertTrue(slot.queue.isEmpty)
        XCTAssertEqual(slot.clientId, "c2")
    }

    func testEndGenerationOrphansEverything() {
        var slot = InteractionSlot()
        _ = slot.beginGeneration(clientId: "c1")
        _ = slot.receive(approval("e1"))

        let orphaned = slot.endGeneration()
        XCTAssertEqual(orphaned.map(\.id), ["e1"])
        XCTAssertNil(slot.clientId)
        XCTAssertFalse(slot.canAnswer)
    }

    /// 断代后答复必须失败。凭证的 Peer 已经 dispose，答复会被 host 丢弃；
    /// 让它静默成功会让 UI 以为已处理。
    func testAnswerAfterGenerationEndFails() {
        var slot = InteractionSlot()
        _ = slot.beginGeneration(clientId: "c1")
        _ = slot.receive(approval("e1"))
        _ = slot.endGeneration()

        XCTAssertNil(slot.answer(.result))
    }

    /// 换代后，旧一代的 cancel 帧不该影响新一代的状态。
    func testStaleCancelAfterNewGenerationIsIgnored() {
        var slot = InteractionSlot()
        _ = slot.beginGeneration(clientId: "c1")
        _ = slot.receive(approval("e1"))
        _ = slot.beginGeneration(clientId: "c2")
        _ = slot.receive(approval("e9"))

        XCTAssertNil(slot.cancel(eventId: "e1"))
        XCTAssertEqual(slot.current?.id, "e9")
    }

    /// 答复过的 id 在换代时要清掉，否则新一代里同名 id 的 cancel 会被误判成回响。
    func testAnsweredIdsResetAcrossGenerations() {
        var slot = InteractionSlot()
        _ = slot.beginGeneration(clientId: "c1")
        _ = slot.receive(approval("e1"))
        _ = slot.answer(.result)

        _ = slot.beginGeneration(clientId: "c2")
        _ = slot.receive(approval("e1"))

        XCTAssertEqual(
            slot.cancel(eventId: "e1"),
            .answeredElsewhere,
            "新一代里的同名 id 不该被当成上一代的回响"
        )
    }

    // MARK: - next 语义

    /// 回 `next` 是"我不管"，不是拒绝。只有当所有客户端都回 next 才按 next 放行。
    func testNextIsAValidOutcome() {
        var slot = InteractionSlot()
        _ = slot.beginGeneration(clientId: "c1")
        _ = slot.receive(approval("e1"))

        XCTAssertEqual(slot.answer(.next)?.outcome, .next)
    }

    func testRejectedIsAValidOutcome() {
        var slot = InteractionSlot()
        _ = slot.beginGeneration(clientId: "c1")
        _ = slot.receive(approval("e1"))

        XCTAssertEqual(slot.answer(.rejected)?.outcome, .rejected)
    }
}
