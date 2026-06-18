import XCTest
@testable import CodexRemote

final class TurnDiffStatsTests: XCTestCase {
    func testSingleFileAddRemove() {
        let diff = """
        diff --git a/a.swift b/a.swift
        --- a/a.swift
        +++ b/a.swift
        @@ -1,3 +1,4 @@
         keep
        +added one
        +added two
        -removed one
        """
        let s = TurnDiffStats.parse(diff)
        XCTAssertEqual(s.added, 2)
        XCTAssertEqual(s.removed, 1)
        XCTAssertEqual(s.changedFiles, 1)
        XCTAssertEqual(s.files, ["a.swift"])
    }

    func testExcludesFileHeaderLines() {
        // +++/--- 头不得计入增删
        let diff = """
        diff --git a/x.txt b/x.txt
        --- a/x.txt
        +++ b/x.txt
        @@ -1 +1 @@
        -old
        +new
        """
        let s = TurnDiffStats.parse(diff)
        XCTAssertEqual(s.added, 1)
        XCTAssertEqual(s.removed, 1)
    }

    func testMultipleFiles() {
        let diff = """
        diff --git a/a.swift b/a.swift
        --- a/a.swift
        +++ b/a.swift
        @@ -0,0 +1 @@
        +one
        diff --git a/b.swift b/b.swift
        --- a/b.swift
        +++ b/b.swift
        @@ -1 +0,0 @@
        -gone
        """
        let s = TurnDiffStats.parse(diff)
        XCTAssertEqual(s.added, 1)
        XCTAssertEqual(s.removed, 1)
        XCTAssertEqual(s.changedFiles, 2)
        XCTAssertEqual(s.files, ["a.swift", "b.swift"])
    }

    func testRename() {
        // 纯重命名：无 +/- 数据行，仍计 1 文件，用新路径
        let diff = """
        diff --git a/old.swift b/new.swift
        similarity index 100%
        rename from old.swift
        rename to new.swift
        """
        let s = TurnDiffStats.parse(diff)
        XCTAssertEqual(s.added, 0)
        XCTAssertEqual(s.removed, 0)
        XCTAssertEqual(s.changedFiles, 1)
        XCTAssertEqual(s.files, ["new.swift"])
    }

    func testBinaryFile() {
        let diff = """
        diff --git a/img.png b/img.png
        Binary files a/img.png and b/img.png differ
        """
        let s = TurnDiffStats.parse(diff)
        XCTAssertEqual(s.added, 0)
        XCTAssertEqual(s.removed, 0)
        XCTAssertEqual(s.changedFiles, 1)
        XCTAssertEqual(s.files, ["img.png"])
    }

    func testDeletedFileUsesOldPath() {
        let diff = """
        diff --git a/gone.swift b/gone.swift
        deleted file mode 100644
        --- a/gone.swift
        +++ /dev/null
        @@ -1,2 +0,0 @@
        -line one
        -line two
        """
        let s = TurnDiffStats.parse(diff)
        XCTAssertEqual(s.added, 0)
        XCTAssertEqual(s.removed, 2)
        XCTAssertEqual(s.changedFiles, 1)
        XCTAssertEqual(s.files, ["gone.swift"])
    }

    func testNoNewlineMarkerIgnored() {
        let diff = """
        diff --git a/n.txt b/n.txt
        --- a/n.txt
        +++ b/n.txt
        @@ -1 +1 @@
        -old
        +new
        \\ No newline at end of file
        """
        let s = TurnDiffStats.parse(diff)
        XCTAssertEqual(s.added, 1)
        XCTAssertEqual(s.removed, 1)
    }

    func testEmptyDiff() {
        let s = TurnDiffStats.parse("")
        XCTAssertEqual(s.added, 0)
        XCTAssertEqual(s.removed, 0)
        XCTAssertEqual(s.changedFiles, 0)
        XCTAssertEqual(s.files, [])
    }

    func testThousandsScale() {
        var lines = ["diff --git a/big.txt b/big.txt", "--- a/big.txt", "+++ b/big.txt", "@@ -1 +1 @@"]
        lines += Array(repeating: "+x", count: 2024)
        lines += Array(repeating: "-y", count: 626)
        let s = TurnDiffStats.parse(lines.joined(separator: "\n"))
        XCTAssertEqual(s.added, 2024)
        XCTAssertEqual(s.removed, 626)
        XCTAssertEqual(s.changedFiles, 1)
    }
}
