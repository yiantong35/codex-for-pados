import XCTest
@testable import CodexRemote

@MainActor
final class SessionControlTests: XCTestCase {
    private func jsonObject<T: Encodable>(_ v: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(v)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    func testRenameParamsUsesNameField() throws {
        let obj = try jsonObject(ThreadSetNameParams(threadId: "t1", name: "新标题"))
        XCTAssertEqual(obj["threadId"] as? String, "t1")
        XCTAssertEqual(obj["name"] as? String, "新标题")   // schema 字段名是 name，不是 title/threadName
        XCTAssertNil(obj["title"])
        XCTAssertNil(obj["threadName"])
    }

    func testRollbackParamsUsesNumTurns() throws {
        let obj = try jsonObject(ThreadRollbackParams(threadId: "t1", numTurns: 3))
        XCTAssertEqual(obj["threadId"] as? String, "t1")
        XCTAssertEqual(obj["numTurns"] as? Int, 3)
    }

    func testGoalSetParamsEncodesObjectiveAndStatus() throws {
        let obj = try jsonObject(ThreadGoalSetParams(threadId: "t1", objective: "发版", status: .active))
        XCTAssertEqual(obj["objective"] as? String, "发版")
        XCTAssertEqual(obj["status"] as? String, "active")
    }

    func testGoalStatusEnumRawValues() {
        XCTAssertEqual(ThreadGoalStatus.active.rawValue, "active")
        XCTAssertEqual(ThreadGoalStatus.paused.rawValue, "paused")
        XCTAssertEqual(ThreadGoalStatus.blocked.rawValue, "blocked")
        XCTAssertEqual(ThreadGoalStatus.usageLimited.rawValue, "usageLimited")
        XCTAssertEqual(ThreadGoalStatus.budgetLimited.rawValue, "budgetLimited")
        XCTAssertEqual(ThreadGoalStatus.complete.rawValue, "complete")
    }

    func testSimpleParamsOnlyThreadId() throws {
        for obj in [try jsonObject(ThreadArchiveParams(threadId: "t1")),
                    try jsonObject(ThreadUnarchiveParams(threadId: "t1")),
                    try jsonObject(ThreadDeleteParams(threadId: "t1")),
                    try jsonObject(ThreadCompactStartParams(threadId: "t1")),
                    try jsonObject(ThreadGoalGetParams(threadId: "t1")),
                    try jsonObject(ThreadGoalClearParams(threadId: "t1"))] {
            XCTAssertEqual(obj["threadId"] as? String, "t1")
        }
    }

    func testGoalGetResponseDecodesNullGoal() throws {
        let data = Data(#"{"goal":null}"#.utf8)
        let resp = try JSONDecoder().decode(ThreadGoalGetResponse.self, from: data)
        XCTAssertNil(resp.goal)
    }

    func testGoalGetResponseDecodesGoal() throws {
        let json = #"""
        {"goal":{"threadId":"t1","objective":"发版","status":"active","createdAt":1,"updatedAt":2,"timeUsedSeconds":30,"tokensUsed":100,"tokenBudget":500}}
        """#
        let resp = try JSONDecoder().decode(ThreadGoalGetResponse.self, from: Data(json.utf8))
        XCTAssertEqual(resp.goal?.threadId, "t1")
        XCTAssertEqual(resp.goal?.objective, "发版")
        XCTAssertEqual(resp.goal?.status, .active)
        XCTAssertEqual(resp.goal?.tokenBudget, 500)
        XCTAssertEqual(resp.goal?.tokensUsed, 100)
    }

    func testGoalSetResponseRequiresGoal() throws {
        let json = #"""
        {"goal":{"threadId":"t1","objective":"发版","status":"complete","createdAt":1,"updatedAt":2,"timeUsedSeconds":30,"tokensUsed":100}}
        """#
        let resp = try JSONDecoder().decode(ThreadGoalSetResponse.self, from: Data(json.utf8))
        XCTAssertEqual(resp.goal.status, .complete)
        XCTAssertNil(resp.goal.tokenBudget)   // tokenBudget 可选，缺省解为 nil
    }

    func testNameUpdatedNotificationUsesThreadNameField() throws {
        // 广播 thread/name/updated 的 payload 字段名是 threadName（可空），不是 name
        let data = Data(#"{"threadId":"t1","threadName":"改后名字"}"#.utf8)
        let n = try JSONDecoder().decode(ThreadNameUpdatedNotification.self, from: data)
        XCTAssertEqual(n.threadId, "t1")
        XCTAssertEqual(n.threadName, "改后名字")

        let nullData = Data(#"{"threadId":"t1","threadName":null}"#.utf8)
        let n2 = try JSONDecoder().decode(ThreadNameUpdatedNotification.self, from: nullData)
        XCTAssertNil(n2.threadName)
    }

    func testGoalUpdatedNotificationDecodes() throws {
        let json = #"""
        {"threadId":"t1","goal":{"threadId":"t1","objective":"发版","status":"active","createdAt":1,"updatedAt":2,"timeUsedSeconds":30,"tokensUsed":100},"turnId":"turn-1"}
        """#
        let n = try JSONDecoder().decode(ThreadGoalUpdatedNotification.self, from: Data(json.utf8))
        XCTAssertEqual(n.threadId, "t1")
        XCTAssertEqual(n.goal.objective, "发版")
        XCTAssertEqual(n.turnId, "turn-1")
    }

    func testMethodConstants() {
        XCTAssertEqual(RPCMethod.threadArchive, "thread/archive")
        XCTAssertEqual(RPCMethod.threadUnarchive, "thread/unarchive")
        XCTAssertEqual(RPCMethod.threadDelete, "thread/delete")
        XCTAssertEqual(RPCMethod.threadNameSet, "thread/name/set")
        XCTAssertEqual(RPCMethod.threadRollback, "thread/rollback")
        XCTAssertEqual(RPCMethod.threadCompactStart, "thread/compact/start")
        XCTAssertEqual(RPCMethod.threadGoalSet, "thread/goal/set")
        XCTAssertEqual(RPCMethod.threadGoalGet, "thread/goal/get")
        XCTAssertEqual(RPCMethod.threadGoalClear, "thread/goal/clear")
    }

    func testNotificationConstants() {
        XCTAssertEqual(ServerNotificationMethod.threadArchived, "thread/archived")
        XCTAssertEqual(ServerNotificationMethod.threadUnarchived, "thread/unarchived")
        XCTAssertEqual(ServerNotificationMethod.threadDeleted, "thread/deleted")
        XCTAssertEqual(ServerNotificationMethod.threadNameUpdated, "thread/name/updated")
        XCTAssertEqual(ServerNotificationMethod.threadGoalUpdated, "thread/goal/updated")
        XCTAssertEqual(ServerNotificationMethod.threadGoalCleared, "thread/goal/cleared")
    }

    // MARK: - store 层：管理动作调用 + 广播驱动列表刷新（Task 3）

    private func makeStore() async -> (ProjectsStore, MockTransport, JSONRPCClient) {
        let mock = MockTransport()
        await mock.setAutoRespond(true)   // 管理动作走 rpc.send 请求-响应，需自动应答否则永久挂起
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        let store = ProjectsStore()
        await store.attach(rpc: rpc)   // 注入 rpc 并启动广播监听
        return (store, mock, rpc)
    }

    private func thread(_ id: String, name: String? = nil) -> ThreadSummary {
        ThreadSummary(id: id, sessionId: id, preview: "p", modelProvider: "openai",
                      createdAt: 0, updatedAt: 1, cwd: "/r", cliVersion: "0",
                      name: name, gitInfo: GitInfoSummary(sha: nil, branch: "main", originUrl: "o/r"))
    }

    func testArchiveSendsMethod() async throws {
        let (store, mock, _) = await makeStore()
        await store.archive(threadId: "t1")
        try await waitUntil { await mock.sent.contains { $0.contains("thread/archive") } }
        let sent = await mock.sent.first { $0.contains("thread/archive") }!
        XCTAssertTrue(sent.contains(#""threadId":"t1""#), sent)
    }

    func testRenameSendsNameField() async throws {
        let (store, mock, _) = await makeStore()
        await store.rename(threadId: "t1", name: "新名")
        try await waitUntil { await mock.sent.contains { $0.contains("thread/name/set") } }
        let sent = await mock.sent.first { $0.contains("thread/name/set") }!
        XCTAssertTrue(sent.contains(#""name":"新名""#), sent)
    }

    func testRollbackSendsNumTurns() async throws {
        let (store, mock, _) = await makeStore()
        await store.rollback(threadId: "t1", numTurns: 2)
        try await waitUntil { await mock.sent.contains { $0.contains("thread/rollback") } }
        let sent = await mock.sent.first { $0.contains("thread/rollback") }!
        XCTAssertTrue(sent.contains(#""numTurns":2"#), sent)
        XCTAssertTrue(sent.contains(#""threadId":"t1""#), sent)
    }

    func testDeleteSendsMethod() async throws {
        let (store, mock, _) = await makeStore()
        await store.delete(threadId: "t1")
        try await waitUntil { await mock.sent.contains { $0.contains("thread/delete") } }
    }

    func testCompactSendsMethod() async throws {
        let (store, mock, _) = await makeStore()
        await store.compact(threadId: "t1")
        try await waitUntil { await mock.sent.contains { $0.contains("thread/compact/start") } }
    }

    func testGoalSetGetClearSend() async throws {
        let (store, mock, _) = await makeStore()
        await store.setGoal(threadId: "t1", objective: "发版", status: .active)
        await store.clearGoal(threadId: "t1")
        try await waitUntil { await mock.sent.contains { $0.contains("thread/goal/set") } }
        try await waitUntil { await mock.sent.contains { $0.contains("thread/goal/clear") } }
        let setFrame = await mock.sent.first { $0.contains("thread/goal/set") }!
        XCTAssertTrue(setFrame.contains(#""objective":"发版""#), setFrame)
    }

    func testDeletedBroadcastRemovesThread() async throws {
        let (store, mock, _) = await makeStore()
        store.ingest([thread("t1"), thread("t2")])
        await mock.feed(#"{"jsonrpc":"2.0","method":"thread/deleted","params":{"threadId":"t1"}}"#)
        try await waitUntil { !store.allThreadsSorted.contains { $0.id == "t1" } }
        XCTAssertTrue(store.allThreadsSorted.contains { $0.id == "t2" })
    }

    func testNameUpdatedBroadcastRenamesThread() async throws {
        let (store, mock, _) = await makeStore()
        store.ingest([thread("t1", name: "旧名")])
        await mock.feed(#"{"jsonrpc":"2.0","method":"thread/name/updated","params":{"threadId":"t1","threadName":"新名"}}"#)
        try await waitUntil { store.allThreadsSorted.first { $0.id == "t1" }?.name == "新名" }
    }

    private func waitUntil(timeout: TimeInterval = 2.0, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("waitUntil timed out")
    }
}
