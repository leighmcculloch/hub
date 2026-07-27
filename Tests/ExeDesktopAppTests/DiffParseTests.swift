import XCTest
@testable import ExeDesktopApp

/// Turning a unified diff into the rows the sidebar renders.
final class DiffParseTests: XCTestCase {

    private func parse(_ diff: String, includeFileHeaders: Bool = false) -> ParsedDiff {
        ParsedDiff.parse(diff, includeFileHeaders: includeFileHeaders)
    }

    // MARK: - Content that looks like a header

    /// The bug: deleting a line starting with "-- " arrives as "--- …", which
    /// was taken for the `--- a/file` header and dropped. SQL comments and
    /// signature delimiters both start that way.
    func testADeletedLineStartingWithTwoDashesIsKept() {
        let parsed = parse("""
        @@ -1,2 +1 @@
        --- a SQL comment
         keep
        """)
        XCTAssertEqual(parsed.deletions, 1)
        XCTAssertEqual(parsed.rows.filter { $0.kind == .deletion }.map(\.text),
                       ["-- a SQL comment"])
    }

    /// The mirror case: adding a line starting with "++ ".
    func testAnAddedLineStartingWithTwoPlusesIsKept() {
        let parsed = parse("""
        @@ -1 +1,2 @@
         keep
        +++ signature
        """)
        XCTAssertEqual(parsed.additions, 1)
        XCTAssertEqual(parsed.rows.filter { $0.kind == .addition }.map(\.text), ["++ signature"])
    }

    /// A deleted line whose content happens to read "index …".
    func testAContentLineStartingWithIndexIsKept() {
        let parsed = parse("""
        @@ -1,2 +1 @@
        -index the documents
         keep
        """)
        XCTAssertEqual(parsed.deletions, 1)
    }

    /// The real headers still have to be dropped, or every file would carry
    /// three lines of blob noise.
    func testRealFileHeadersAreStillDropped() {
        let parsed = parse("""
        diff --git a/x.txt b/x.txt
        index 3367afd..e634153 100644
        --- a/x.txt
        +++ b/x.txt
        @@ -1 +1,2 @@
         old
        +new
        """)
        XCTAssertEqual(parsed.additions, 1)
        XCTAssertEqual(parsed.deletions, 0)
        XCTAssertFalse(parsed.rows.contains { $0.text.contains("3367afd") })
        XCTAssertFalse(parsed.rows.contains { $0.text == "a/x.txt" })
    }

    /// After one file's hunks, the *next* file's headers must be recognised
    /// again — the in-hunk state has to reset per file.
    func testHeadersAreDroppedAgainForTheNextFile() {
        let parsed = parse("""
        diff --git a/a.txt b/a.txt
        --- a/a.txt
        +++ b/a.txt
        @@ -1 +1 @@
        -one
        +two
        diff --git a/b.txt b/b.txt
        index 111..222 100644
        --- a/b.txt
        +++ b/b.txt
        @@ -1 +1 @@
        -three
        +four
        """, includeFileHeaders: true)

        XCTAssertEqual(parsed.additions, 2)
        XCTAssertEqual(parsed.deletions, 2)
        XCTAssertFalse(parsed.rows.contains { $0.text.contains("111..222") },
                       "second file's index line leaked through")
        XCTAssertEqual(parsed.rows.filter { $0.kind == .file }.map(\.text), ["a.txt", "b.txt"])
    }

    /// Byte-for-byte output from `git diff` on a file of SQL comments — the
    /// case that exposed this. Three deletions, none of which may vanish.
    func testARealGitDiffOfCommentLines() {
        let parsed = parse("""
        diff --git a/q.sql b/q.sql
        index bb505fe..2fa992c 100644
        --- a/q.sql
        +++ b/q.sql
        @@ -1,4 +1 @@
        --- a SQL comment
         keep
        --- another
        -++ plus line
        """, includeFileHeaders: true)

        XCTAssertEqual(parsed.deletions, 3)
        XCTAssertEqual(parsed.rows.filter { $0.kind == .deletion }.map(\.text),
                       ["-- a SQL comment", "-- another", "++ plus line"])
        // The file's own headers are still suppressed.
        XCTAssertFalse(parsed.rows.contains { $0.text.contains("bb505fe") })
    }

    // MARK: - Hunks and line numbers

    func testLineNumbersFollowTheHunkHeader() {
        let parsed = parse("""
        @@ -10,3 +20,4 @@ func example()
         context
        -removed
        +added
        +also added
        """)
        // The context line consumes old line 10 and new line 20, so the
        // deletion below it is old line 11.
        let numbered = parsed.rows.filter { $0.number != nil }
        XCTAssertEqual(numbered.map { "\($0.kind):\($0.number!)" },
                       ["context:20", "deletion:11", "addition:21", "addition:22"])
    }

    /// A second hunk in the same file restarts numbering from its own header.
    func testASecondHunkRestartsNumbering() {
        let parsed = parse("""
        @@ -1,1 +1,1 @@
        +first
        @@ -50,1 +60,1 @@
        +later
        """)
        XCTAssertEqual(parsed.rows.filter { $0.kind == .addition }.map(\.number), [1, 60])
    }

    func testTheHunkContextSuffixIsKeptSeparately() {
        let parsed = parse("@@ -1,3 +1,4 @@ func example()")
        let hunk = parsed.rows.first { $0.kind == .hunk }
        XCTAssertEqual(hunk?.text, "@@ -1,3 +1,4 @@")
        XCTAssertEqual(hunk?.detail, "func example()")
    }

    func testAHunkWithoutAContextSuffixHasNoDetail() {
        XCTAssertNil(parse("@@ -1 +1 @@").rows.first { $0.kind == .hunk }?.detail)
    }

    /// Single-line hunks omit the count: "@@ -1 +1 @@".
    func testCountlessHunkHeadersStillSetNumbers() {
        let parsed = parse("""
        @@ -7 +9 @@
        -gone
        +here
        """)
        XCTAssertEqual(parsed.rows.filter { $0.kind == .deletion }.first?.number, 7)
        XCTAssertEqual(parsed.rows.filter { $0.kind == .addition }.first?.number, 9)
    }

    // MARK: - Totals

    func testTotalsCountOnlyContentLines() {
        let parsed = parse("""
        diff --git a/x b/x
        --- a/x
        +++ b/x
        @@ -1,2 +1,2 @@
        -old
        +new
         same
        """)
        XCTAssertEqual(parsed.additions, 1)
        XCTAssertEqual(parsed.deletions, 1)
    }

    // MARK: - Shapes that aren't ordinary edits

    func testABinaryFileNoticeBecomesAMetaRow() {
        let parsed = parse("""
        diff --git a/i.png b/i.png
        Binary files /dev/null and b/i.png differ
        """)
        XCTAssertTrue(parsed.rows.contains { $0.kind == .meta && $0.text.contains("Binary files") })
        XCTAssertEqual(parsed.additions, 0)
    }

    func testTheNoNewlineMarkerIsNotCountedAsContent() {
        let parsed = parse("""
        @@ -1 +1 @@
        -old
        \\ No newline at end of file
        +new
        """)
        XCTAssertEqual(parsed.additions, 1)
        XCTAssertEqual(parsed.deletions, 1)
        XCTAssertTrue(parsed.rows.contains { $0.kind == .meta })
    }

    func testAnEmptyDiffProducesNoRows() {
        let parsed = parse("")
        XCTAssertTrue(parsed.rows.isEmpty)
        XCTAssertEqual(parsed.additions, 0)
        XCTAssertEqual(parsed.deletions, 0)
    }

    /// A trailing newline must not add a phantom row at the end of every diff.
    func testATrailingNewlineDoesNotAddARow() {
        XCTAssertEqual(parse("@@ -1 +1 @@\n+a\n").rows.count,
                       parse("@@ -1 +1 @@\n+a").rows.count)
    }

    // MARK: - Display

    func testTabsAreExpandedAndCarriageReturnsStripped() {
        let parsed = parse("@@ -1 +1 @@\n+\tindented\r")
        XCTAssertEqual(parsed.rows.last?.text, "    indented")
    }

    /// Row ids must be unique — they key the rendered list and the scroll
    /// target.
    func testRowIdentifiersAreUnique() {
        let parsed = parse("""
        diff --git a/a b/a
        @@ -1,2 +1,2 @@
        -x
        +y
         z
        """, includeFileHeaders: true)
        XCTAssertEqual(Set(parsed.rows.map(\.id)).count, parsed.rows.count)
    }

    /// The file row's text is what the scroll-to-path lookup matches against,
    /// so it has to be the plain post-rename path.
    func testTheFileRowTextIsTheBPath() {
        let parsed = parse("diff --git a/old/x.txt b/new/x.txt", includeFileHeaders: true)
        XCTAssertEqual(parsed.rows.first { $0.kind == .file }?.text, "new/x.txt")
    }

    func testFileRowsAreOmittedForASingleFileDiff() {
        let parsed = parse("diff --git a/x b/x\n@@ -1 +1 @@\n+a", includeFileHeaders: false)
        XCTAssertFalse(parsed.rows.contains { $0.kind == .file })
    }
}
