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
}
