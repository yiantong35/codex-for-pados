import XCTest

/// 模拟器自验驱动（self-verify-on-simulator 基础设施）：真实点击导航栏/会话流，
/// 覆盖无头 unit-test 宿主无法物化的 toolbar chrome（BACKLOG line89 的补偿通道）。
/// 前置：模拟器已配对 + dev 侧 relay-dialout 在线（连不上则跳过而非误报）。
@MainActor
final class ConversationFlowUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    func test_selectConversation_toolbarAndJumpToLatest() throws {
        let app = XCUIApplication()
        // activate 而非 launch：不强杀已连接的 app 进程（强杀=突断,会触发 dev 侧
        // rehandshake 缺陷[BACKLOG 在案]制造连接风暴）;外部先用 simctl launch 建好连接。
        app.activate()

        // 等连接+会话列表（relay 往返;dev 侧退避封顶 30s,宽限 2 分钟并主动点「重新连接」）；
        // 连不上视为环境未就绪跳过。
        let header = app.staticTexts["对话"].firstMatch
        let deadline = Date().addingTimeInterval(120)
        while !header.exists, Date() < deadline {
            let reconnect = app.buttons["重新连接"].firstMatch
            if reconnect.exists { reconnect.tap() }
            RunLoop.current.run(until: Date().addingTimeInterval(3))
        }
        guard header.exists else {
            attach(app, name: "connect-timeout")
            throw XCTSkip("relay 未连接（dev 侧 dialout 离线？）——跳过 UI 自验")
        }

        // 选中一个长会话（anything… 网络问答长文）；找不到则点「对话」区第一行。
        let anyThread = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS 'anything'")).firstMatch
        if anyThread.waitForExistence(timeout: 5) {
            anyThread.tap()
        } else {
            header.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
                .withOffset(CGVector(dx: 0, dy: 70)).tap()
        }

        // ① 刷新按钮常驻（选中会话后出现在导航栏）。
        let refresh = app.buttons["刷新对话"].firstMatch
        XCTAssertTrue(refresh.waitForExistence(timeout: 20), "选中会话后导航栏应有常驻刷新按钮")

        // ② 正常态无状态胶囊（两态定案：运行/空闲不显示）。
        sleep(2)
        XCTAssertFalse(app.staticTexts["空闲"].exists, "正常态不得显示「空闲」胶囊")
        XCTAssertFalse(app.staticTexts["运行中"].exists, "正常态不得显示「运行中」胶囊")

        // ③ 进会话初始定位到最新：加载完成后应贴底 → 「回到最新」浮钮不出现。
        let jump = app.buttons["回到最新"].firstMatch
        sleep(2)
        XCTAssertFalse(jump.exists, "初始应定位到最新（贴底不显示回底浮钮）")
        attach(app, name: "after-open")

        // ④ 上滑离底 → 浮钮出现；点击 → 回底消失。
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.35))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.85))
        for _ in 0..<3 { from.press(forDuration: 0.05, thenDragTo: to) }
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        attach(app, name: "scrolled-up")   // 先留现场再断言
        XCTAssertTrue(jump.waitForExistence(timeout: 5), "上滑离底后应出现「回到最新」浮钮")
        jump.tap()
        let gone = !jump.waitForExistence(timeout: 2) || waitDisappear(jump, timeout: 6)
        XCTAssertTrue(gone, "点击回底后浮钮应消失（贴底隐藏）")
        attach(app, name: "after-jump")
    }

    private func waitDisappear(_ el: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !el.exists { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        return !el.exists
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        // 顺手落 /tmp 供会话外读取（失败静默，断言为准）。
        try? app.screenshot().pngRepresentation.write(
            to: URL(fileURLWithPath: "/tmp/uiverify-\(name).png"))
    }
}
