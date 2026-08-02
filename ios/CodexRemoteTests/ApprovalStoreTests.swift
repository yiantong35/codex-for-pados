import XCTest
@testable import CodexRemote

@MainActor
final class ApprovalStoreTests: XCTestCase {
    func testV2CommandRequestEnqueuesCard() async throws {
        let store = ApprovalStore()
        let req = JSONRPCRequest(id: .string("r1"),
            method: ServerRequestMethod.cmdApprovalV2,
            params: AnyCodable(["threadId": "t1", "turnId": "T1", "itemId": "I1", "command": "rm -rf x"]))
        store.handle(request: req)
        XCTAssertEqual(store.cards.count, 1)
        XCTAssertEqual(store.cards.first?.threadId, "t1")
        XCTAssertEqual(store.cards.first?.title, "rm -rf x")
        XCTAssertFalse(store.cards.first?.isFileChange ?? true)
    }

    func testV2ApproveEncodesAccept() throws {
        let store = ApprovalStore()
        let resp = store.responseBody(for: ServerRequestMethod.cmdApprovalV2, decision: .approve)
        let s = String(data: try JSONEncoder().encode(resp), encoding: .utf8)!
        XCTAssertTrue(s.contains("accept"))
    }

    func testV2ApproveWithPrefixEncodesAmendment() throws {
        let store = ApprovalStore()
        let resp = store.responseBody(for: ServerRequestMethod.cmdApprovalV2,
                                      decision: .approveForSessionPrefix(["git", "status"]))
        let s = String(data: try JSONEncoder().encode(resp), encoding: .utf8)!
        XCTAssertTrue(s.contains("acceptWithExecpolicyAmendment"))
        XCTAssertTrue(s.contains("execpolicy_amendment"))
    }

    func testV2DeclineEncodes() throws {
        let store = ApprovalStore()
        let resp = store.responseBody(for: ServerRequestMethod.cmdApprovalV2, decision: .deny)
        XCTAssertTrue(String(data: try JSONEncoder().encode(resp), encoding: .utf8)!.contains("decline"))
    }

    func testLegacyExecApprovalUsesReviewDecision() throws {
        let store = ApprovalStore()
        let resp = store.responseBody(for: ServerRequestMethod.execApprovalLegacy, decision: .approve)
        XCTAssertTrue(String(data: try JSONEncoder().encode(resp), encoding: .utf8)!.contains("approved"))
    }

    func testLegacyDenyUsesReviewDecisionDenied() throws {
        let store = ApprovalStore()
        let resp = store.responseBody(for: ServerRequestMethod.execApprovalLegacy, decision: .deny)
        XCTAssertTrue(String(data: try JSONEncoder().encode(resp), encoding: .utf8)!.contains("denied"))
    }

    func testFileChangeV2EnqueuesFileCard() throws {
        let store = ApprovalStore()
        let req = JSONRPCRequest(id: .string("f1"),
            method: ServerRequestMethod.fileApprovalV2,
            params: AnyCodable(["threadId": "t1", "file": "main.swift", "diff": "+ line"]))
        store.handle(request: req)
        XCTAssertEqual(store.cards.first?.isFileChange, true)
    }

    // 端到端：经 JSONRPCClient.serverRequests() feed → 真实 coordinator 接线 → resolve → mock.sent 含正确 response。
    func testResolveSendsResponseWithMatchingRequestId() async throws {
        let mock = MockTransport()
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        let coord = ApprovalCoordinator(store: ApprovalStore(), projects: ProjectsStore())
        await coord.bind(rpc: rpc)
        let store = coord.store

        let frame = #"{"jsonrpc":"2.0","id":"r9","method":"item/commandExecution/requestApproval","params":{"threadId":"t1","command":"ls"}}"#
        await mock.feed(frame)
        // 等待 server-request 流送达
        try await waitUntil { store.cards.count == 1 }
        let card = store.cards.first!
        await store.resolve(card: card, choice: .approve)
        try await waitUntil { await mock.sent.contains { $0.contains("\"id\":\"r9\"") } }
        let sent = await mock.sent
        let respFrame = sent.first { $0.contains("\"id\":\"r9\"") }!
        XCTAssertTrue(respFrame.contains("accept"))
        XCTAssertTrue(store.cards.isEmpty)
    }

    // MARK: - F4（P1）权限审批协议正确响应 + 知情展示

    /// permissions 请求必须返回 PermissionsRequestApprovalResponse（含 permissions+scope），
    /// 不得误落 CommandExecutionApprovalResponse（仅含 decision）。
    func test_permissions_approval_returns_permissions_response_not_command() throws {
        let store = ApprovalStore()
        let req = JSONRPCRequest(id: .string("p1"),
            method: ServerRequestMethod.permsApprovalV2,
            params: AnyCodable(["threadId": "t1", "reason": "需要联网",
                                "permissions": ["network": ["enabled": true]],
                                "cwd": "/work"]))
        store.handle(request: req)
        let body = store.responseBody(for: ServerRequestMethod.permsApprovalV2, decision: .approve)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as! [String: Any]
        XCTAssertNotNil(json["permissions"])
        XCTAssertNotNil(json["scope"])
        XCTAssertNil(json["decision"])
    }

    /// 命令/文件/权限三类各用对应响应类型，绝不串用。
    func test_three_approval_kinds_use_distinct_response_types() throws {
        let store = ApprovalStore()
        let cmd = try JSONSerialization.jsonObject(with:
            JSONEncoder().encode(store.responseBody(for: ServerRequestMethod.cmdApprovalV2, decision: .approve))) as! [String: Any]
        XCTAssertNotNil(cmd["decision"]); XCTAssertNil(cmd["permissions"])
        let file = try JSONSerialization.jsonObject(with:
            JSONEncoder().encode(store.responseBody(for: ServerRequestMethod.fileApprovalV2, decision: .approve))) as! [String: Any]
        XCTAssertNotNil(file["decision"]); XCTAssertNil(file["permissions"])
        let perm = try JSONSerialization.jsonObject(with:
            JSONEncoder().encode(store.responseBody(for: ServerRequestMethod.permsApprovalV2, decision: .approve))) as! [String: Any]
        XCTAssertNotNil(perm["permissions"]); XCTAssertNotNil(perm["scope"]); XCTAssertNil(perm["decision"])
    }

    /// scope 随决定映射：approve→turn、approveForSessionPrefix→session；deny 时不授予（network.enabled=false）。
    func test_permissions_scope_and_grant_reflect_decision() throws {
        let store = ApprovalStore()
        func perms(_ d: ApprovalChoice) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with:
                JSONEncoder().encode(store.responseBody(for: ServerRequestMethod.permsApprovalV2, decision: d))) as! [String: Any]
        }
        XCTAssertEqual(try perms(.approve)["scope"] as? String, "turn")
        XCTAssertEqual(try perms(.approveForSessionPrefix(["x"]))["scope"] as? String, "session")
        let denied = try perms(.deny)
        XCTAssertEqual(denied["scope"] as? String, "turn")
        let net = (denied["permissions"] as? [String: Any])?["network"] as? [String: Any]
        XCTAssertEqual(net?["enabled"] as? Bool, false)
    }

    /// handle 解析权限请求的知情要素（reason + network/fileSystem 条目）存入卡片。
    func test_permissions_request_parsed_into_card_for_informed_display() throws {
        let store = ApprovalStore()
        let req = JSONRPCRequest(id: .string("p2"),
            method: ServerRequestMethod.permsApprovalV2,
            params: AnyCodable(["threadId": "t1", "reason": "需要读写文件",
                                "permissions": ["network": ["enabled": true],
                                                "fileSystem": ["read": ["/a"], "write": ["/b"]]],
                                "cwd": "/work"]))
        store.handle(request: req)
        let card = store.cards.first
        XCTAssertEqual(card?.isPermissions, true)
        XCTAssertEqual(card?.reason, "需要读写文件")
        XCTAssertEqual(card?.requestedNetworkEnabled, true)
        XCTAssertEqual(card?.requestedFileSystem ?? [], ["/a", "/b"])
        XCTAssertEqual(card?.threadId, "t1")
        XCTAssertEqual(card?.detail, "/work")
    }

    // F4-fix：批准授予档案 MUST 回显请求，杜绝硬编码 network 过授（最小权限）。

    /// 仅请求 fileSystem 的权限请求，批准后授予档案回显请求的 fileSystem，
    /// 且绝不出现未请求的 network 授予（既不过授 network，也不漏授 fileSystem）。
    func test_permissions_filesystem_only_approve_echoes_request_no_unrequested_network() async throws {
        let store = ApprovalStore()
        var captured: AnyCodable?
        store.resolver = { _, body in captured = body }
        let req = JSONRPCRequest(id: .string("p3"),
            method: ServerRequestMethod.permsApprovalV2,
            params: AnyCodable(["threadId": "t1", "reason": "需要读写文件",
                                "permissions": ["fileSystem": ["read": ["/a"], "write": ["/b"]]],
                                "cwd": "/work"]))
        store.handle(request: req)
        let card = store.cards.first!
        await store.resolve(card: card, choice: .approve)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(captured!)) as! [String: Any]
        let perms = json["permissions"] as! [String: Any]
        // 回显请求的 fileSystem read+write。
        let fs = perms["fileSystem"] as? [String: Any]
        XCTAssertEqual(fs?["read"] as? [String], ["/a"])
        XCTAssertEqual(fs?["write"] as? [String], ["/b"])
        // 未请求 network → 授予中绝不出现 network egress（过授）。
        XCTAssertNil(perms["network"], "未请求 network 却授予了 network egress（过授）")
    }

    /// 仅请求 network 的权限请求，批准后回显 network 授予、不夹带未请求的 fileSystem。
    func test_permissions_network_only_approve_echoes_network_no_filesystem() async throws {
        let store = ApprovalStore()
        var captured: AnyCodable?
        store.resolver = { _, body in captured = body }
        let req = JSONRPCRequest(id: .string("p4"),
            method: ServerRequestMethod.permsApprovalV2,
            params: AnyCodable(["threadId": "t1", "reason": "需要联网",
                                "permissions": ["network": ["enabled": true]],
                                "cwd": "/work"]))
        store.handle(request: req)
        let card = store.cards.first!
        await store.resolve(card: card, choice: .approve)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(captured!)) as! [String: Any]
        let perms = json["permissions"] as! [String: Any]
        let net = perms["network"] as? [String: Any]
        XCTAssertEqual(net?["enabled"] as? Bool, true)
        XCTAssertNil(perms["fileSystem"], "未请求 fileSystem 却授予了 fileSystem 访问（过授）")
    }

    // MARK: - reconnect-resync item 1：重放幂等去重

    /// 断线标记 awaitingRecovery → 同 requestId 重放 → 只剩一张卡且标记已清。
    func test_reconnect_replay_same_request_id_dedups_and_clears_recovery() {
        let store = ApprovalStore()
        let req = JSONRPCRequest(id: .string("r1"),
            method: ServerRequestMethod.cmdApprovalV2,
            params: AnyCodable(["threadId": "t1", "command": "rm -rf x"]))
        store.handle(request: req)
        XCTAssertEqual(store.cards.count, 1)

        store.handleConnectionLost()
        XCTAssertEqual(store.cards.first?.awaitingRecovery, true, "断线应标记待恢复")

        // 重连后 server 用原始 requestId 重放同一审批
        store.handle(request: req)
        XCTAssertEqual(store.cards.count, 1, "同 requestId 重放不得产生第二张卡")
        XCTAssertEqual(store.cards.first?.awaitingRecovery, false, "重放原地替换应清除断线标记")
    }

    /// 不同 requestId → 两张卡（不误合并）。
    func test_distinct_request_ids_keep_separate_cards() {
        let store = ApprovalStore()
        store.handle(request: JSONRPCRequest(id: .string("r1"),
            method: ServerRequestMethod.cmdApprovalV2,
            params: AnyCodable(["threadId": "t1", "command": "a"])))
        store.handle(request: JSONRPCRequest(id: .string("r2"),
            method: ServerRequestMethod.cmdApprovalV2,
            params: AnyCodable(["threadId": "t1", "command": "b"])))
        XCTAssertEqual(store.cards.count, 2)
    }

    /// 同 id 重放载荷变化（diff 更新）→ 原地替换取新载荷。
    func test_replay_same_id_updates_payload() {
        let store = ApprovalStore()
        store.handle(request: JSONRPCRequest(id: .string("f1"),
            method: ServerRequestMethod.fileApprovalV2,
            params: AnyCodable(["threadId": "t1", "file": "main.swift", "diff": "+ old"])))
        store.handle(request: JSONRPCRequest(id: .string("f1"),
            method: ServerRequestMethod.fileApprovalV2,
            params: AnyCodable(["threadId": "t1", "file": "main.swift", "diff": "+ new"])))
        XCTAssertEqual(store.cards.count, 1)
        XCTAssertEqual(store.cards.first?.detail, "+ new", "同 id 重放应刷新为新载荷")
    }

    /// 边界回归：断线只标记，绝不自动批准（不调用 resolver）。
    func test_connection_lost_never_auto_approves() {
        let store = ApprovalStore()
        var resolverCalled = false
        store.resolver = { _, _ in resolverCalled = true }
        store.handle(request: JSONRPCRequest(id: .string("r1"),
            method: ServerRequestMethod.cmdApprovalV2,
            params: AnyCodable(["threadId": "t1", "command": "rm"])))
        store.handleConnectionLost()
        XCTAssertFalse(resolverCalled, "断线绝不自动批准")
        XCTAssertEqual(store.cards.count, 1, "断线不移除卡片")
    }

    // 辅助：轮询直到条件满足或超时。
    private func waitUntil(timeout: TimeInterval = 2,
                           _ cond: @escaping () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await cond() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("waitUntil 超时")
    }
}
