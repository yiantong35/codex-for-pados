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
}
