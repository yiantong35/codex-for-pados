import Testing
import Foundation
@testable import CodexRemote

struct EnvironmentInspectorTests {
    private func decode<T: Decodable>(_ t: T.Type, _ j: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(j.utf8))
    }

    @Test func methodConstants() {
        #expect(RPCMethod.gitDiffToRemote == "gitDiffToRemote")
        #expect(RPCMethod.getAuthStatus == "getAuthStatus")
    }
    @Test func decodeGitDiffResponse() throws {
        let r = try decode(GitDiffToRemoteResponse.self, #"{"sha":"abc123","diff":"diff --git a/x b/x\n+one\n-two\n"}"#)
        #expect(r.sha == "abc123")
        #expect(r.diff.contains("diff --git"))
    }
    @Test func decodeAuthStatus() throws {
        let r = try decode(GetAuthStatusResponse.self, #"{"authMethod":"chatgpt","authToken":"t","requiresOpenaiAuth":false}"#)
        #expect(r.authMethod == "chatgpt")
        #expect(r.requiresOpenaiAuth == false)
    }
    @Test func decodeAuthStatusNulls() throws {
        let r = try decode(GetAuthStatusResponse.self, #"{"authMethod":null,"authToken":null,"requiresOpenaiAuth":null}"#)
        #expect(r.authMethod == nil)
    }

    // MARK: - Task 2: 子智能体聚合

    private func notif(_ m: String, item: [String: Any]) -> JSONRPCNotification {
        JSONRPCNotification(method: m, params: AnyCodable(["item": item]))
    }

    @MainActor @Test func reducerAggregatesCollabAgents() {
        var s = ConversationState(threadId: "t")
        let r = ThreadReducer()
        r.apply(notif("item/started", item: [
            "id": "c1", "type": "collabAgentToolCall",
            "agentsStates": ["a1": ["status": "running", "message": "go"],
                             "a2": ["status": "pendingInit"]]
        ]), to: &s)
        #expect(s.subAgents["a1"]?.status == .running)
        #expect(s.subAgents["a2"]?.status == .pendingInit)
        r.apply(notif("item/completed", item: [
            "id": "c1", "type": "collabAgentToolCall",
            "agentsStates": ["a1": ["status": "completed"]]
        ]), to: &s)
        #expect(s.subAgents["a1"]?.status == .completed)
    }

    @MainActor @Test func reducerSubAgentActivityUpdatesPath() {
        var s = ConversationState(threadId: "t")
        let r = ThreadReducer()
        r.apply(notif("item/started", item: [
            "id": "s1", "type": "subAgentActivity",
            "agentThreadId": "a1", "agentPath": "/repo/agents/Hypatia.md", "kind": "started"
        ]), to: &s)
        #expect(s.subAgents["a1"]?.path == "/repo/agents/Hypatia.md")
        #expect(s.subAgents["a1"]?.displayName == "Hypatia.md")
    }

    // MARK: - Task 3: EnvironmentInspectorModel

    @MainActor @Test func diffParamsAndStats() {
        let p = EnvironmentInspectorModel.diffParams(cwd: "/repo")
        #expect(p.cwd == "/repo")
        let stats = EnvironmentInspectorModel.stats(fromDiff: "diff --git a/x b/x\n+a\n+b\n-c\n")
        #expect(stats.added == 2)
        #expect(stats.removed == 1)
        #expect(stats.changedFiles == 1)
    }
}
