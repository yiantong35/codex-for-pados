import Testing
import Foundation
@testable import CodexRemote

struct ReviewPanelTests {
    @Test func parseSingleFileAddDel() {
        let diff = """
        diff --git a/x.swift b/x.swift
        --- a/x.swift
        +++ b/x.swift
        @@ -1,2 +1,3 @@
         context
        -removed
        +added1
        +added2
        """
        let files = UnifiedDiffParser.parse(diff)
        #expect(files.count == 1)
        #expect(files[0].path == "x.swift")
        let lines = files[0].hunks.flatMap(\.lines)
        #expect(lines.contains { $0.kind == .del && $0.text == "removed" })
        #expect(lines.contains { $0.kind == .add && $0.text == "added1" })
        #expect(lines.contains { $0.kind == .context && $0.text == "context" })
    }
    @Test func parseMultiFile() {
        let diff = """
        diff --git a/a.txt b/a.txt
        --- a/a.txt
        +++ b/a.txt
        @@ -1 +1 @@
        -old
        +new
        diff --git a/b.txt b/b.txt
        --- a/b.txt
        +++ b/b.txt
        @@ -0,0 +1 @@
        +hi
        """
        let files = UnifiedDiffParser.parse(diff)
        #expect(files.map(\.path) == ["a.txt", "b.txt"])
    }
    @Test func parseAddDeleteFile() {
        let add = """
        diff --git a/new.txt b/new.txt
        --- /dev/null
        +++ b/new.txt
        @@ -0,0 +1 @@
        +hi
        """
        #expect(UnifiedDiffParser.parse(add)[0].kind == .add)
        let del = """
        diff --git a/gone.txt b/gone.txt
        --- a/gone.txt
        +++ /dev/null
        @@ -1 +0,0 @@
        -bye
        """
        #expect(UnifiedDiffParser.parse(del)[0].kind == .delete)
    }
    @Test func parseRenameAndBinary() {
        let rename = """
        diff --git a/old.txt b/new.txt
        rename from old.txt
        rename to new.txt
        """
        let r = UnifiedDiffParser.parse(rename)
        #expect(r[0].kind == .rename)
        #expect(r[0].oldPath == "old.txt")
        let bin = """
        diff --git a/img.png b/img.png
        Binary files a/img.png and b/img.png differ
        """
        #expect(UnifiedDiffParser.parse(bin)[0].kind == .binary)
    }
    @Test func parseLineNumbers() {
        let diff = """
        diff --git a/x b/x
        --- a/x
        +++ b/x
        @@ -5,2 +5,2 @@
         ctx
        -old
        +new
        """
        let lines = UnifiedDiffParser.parse(diff)[0].hunks.flatMap(\.lines)
        let ctx = lines.first { $0.kind == .context }
        #expect(ctx?.oldLineNo == 5)
        #expect(ctx?.newLineNo == 5)
    }
    @Test func parseEmpty() {
        #expect(UnifiedDiffParser.parse("").isEmpty)
    }
    @Test func gitDiffMethodAndDecode() throws {
        #expect(RPCMethod.gitDiffToRemote == "gitDiffToRemote")
        let r = try JSONDecoder().decode(GitDiffToRemoteResponse.self,
            from: Data(#"{"sha":"abc","diff":"diff --git a/x b/x\n"}"#.utf8))
        #expect(r.sha == "abc")
        #expect(r.diff.contains("diff --git"))
    }
    @Test func diffSourceParsing() {
        let src = ReviewDiffSource(diff: "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n", label: "本轮", cwd: nil)
        #expect(src.files.count == 1)
        #expect(src.isEmpty == false)
        #expect(ReviewDiffSource(diff: "", label: "空", cwd: nil).isEmpty)
    }
    @Test func sourceModeResolve() {
        let turn = "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n"
        let full = "diff --git a/y b/y\n--- a/y\n+++ b/y\n@@ -1 +1 @@\n-c\n+d\n"
        #expect(ReviewDiffSource.resolve(mode: .turn, turnDiff: turn, fullDiff: full).label == "本轮")
        #expect(ReviewDiffSource.resolve(mode: .turn, turnDiff: turn, fullDiff: full).files.first?.path == "x")
        #expect(ReviewDiffSource.resolve(mode: .full, turnDiff: turn, fullDiff: full).files.first?.path == "y")
        // 全量未拉取(nil)→空,面板显示空态
        #expect(ReviewDiffSource.resolve(mode: .full, turnDiff: turn, fullDiff: nil).isEmpty)
    }
    @MainActor @Test func fetchFullDiffCallsGitDiffToRemote() async throws {
        let mock = MockTransport()
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        let store = ConversationStore(rpc: rpc, threadId: "t1")
        // 后台模拟服务端:对 gitDiffToRemote 回 {sha,diff}
        let responder = Task { await Self.replyToGitDiff(mock, diff: "diff --git a/z b/z\n") }
        let diff = await store.fetchFullDiff(cwd: "/repo")
        responder.cancel()
        #expect(diff?.contains("diff --git a/z") == true)
        let sent = await mock.sent
        #expect(sent.contains { $0.contains("gitDiffToRemote") && $0.contains("/repo") })
    }

    /// 测试用模拟服务端:轮询 mock.sent,对 gitDiffToRemote 回注入的 diff。
    private static func replyToGitDiff(_ mock: MockTransport, diff: String) async {
        var answered = false
        for _ in 0..<400 {
            if Task.isCancelled { return }
            let sent = await mock.sent
            for frame in sent {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any],
                      let id = obj["id"] as? String,
                      obj["method"] as? String == "gitDiffToRemote", !answered else { continue }
                answered = true
                let escaped = diff.replacingOccurrences(of: "\n", with: "\\n")
                await mock.feed(#"{"jsonrpc":"2.0","id":"\#(id)","result":{"sha":"abc","diff":"\#(escaped)"}}"#)
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
