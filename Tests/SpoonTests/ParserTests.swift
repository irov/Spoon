import SpoonDiff
import SpoonDomain
import SpoonSVN
import XCTest

final class ParserTests: XCTestCase {
    func testInfoParserRequiresAndMapsWorkingCopyIdentity() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <info><entry kind="dir" path="/tmp/wc" revision="42">
          <url>file:///tmp/repo/trunk</url><relative-url>^/trunk</relative-url>
          <repository><root>file:///tmp/repo</root><uuid>11111111-2222-3333-4444-555555555555</uuid></repository>
          <wc-info><wcroot-abspath>/tmp/wc</wcroot-abspath><schedule>normal</schedule><depth>infinity</depth></wc-info>
        </entry></info>
        """
        let info = try SVNXMLParsers.info(Data(xml.utf8))
        XCTAssertEqual(info.revision, 42)
        XCTAssertEqual(info.workingCopyRoot.path, "/tmp/wc")
        XCTAssertEqual(info.repositoryUUID, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(info.relativeURL, "^/trunk")
    }

    func testStatusParserKeepsLocalAndRemoteOnlyChanges() throws {
        let xml = """
        <?xml version="1.0"?><status><target path="/tmp/wc">
          <entry path="/tmp/wc/modified.txt"><wc-status item="modified" props="normal" revision="3"/></entry>
          <entry path="/tmp/wc/remote.txt"><wc-status item="normal" props="normal" revision="3"/><repos-status item="modified" props="none"/></entry>
          <entry path="/tmp/wc/clean.txt"><wc-status item="normal" props="normal" revision="3"/></entry>
        </target></status>
        """
        let items = try SVNXMLParsers.status(Data(xml.utf8), workingCopyRoot: URL(fileURLWithPath: "/tmp/wc"))
        XCTAssertEqual(items.map(\.relativePath), ["modified.txt", "remote.txt"])
        XCTAssertEqual(items[0].workingCopyStatus, .modified)
        XCTAssertEqual(items[1].remoteStatus, .modified)
    }

    func testLogParserMapsCopyFromMetadata() throws {
        let xml = """
        <?xml version="1.0"?><log><logentry revision="18"><author>alice</author>
          <date>2026-08-05T10:15:30.123456Z</date>
          <paths><path action="A" kind="dir" copyfrom-path="/trunk" copyfrom-rev="17">/branches/release</path></paths>
          <msg>Create release branch</msg></logentry></log>
        """
        let revisions = try SVNXMLParsers.log(Data(xml.utf8))
        XCTAssertEqual(revisions.first?.revision, 18)
        XCTAssertEqual(revisions.first?.changedPaths.first?.copyFromPath, "/trunk")
        XCTAssertEqual(revisions.first?.changedPaths.first?.copyFromRevision, 17)
    }

    func testUnifiedDiffPreservesLineNumbersAndBuildsPairedRows() {
        let text = """
        Index: hello.txt
        ===================================================================
        --- hello.txt\t(revision 1)
        +++ hello.txt\t(working copy)
        @@ -1,2 +1,2 @@
        -hello
        +hello world
         unchanged
        """
        let diff = UnifiedDiffParser.parse(text)
        guard let hunk = diff.files.first?.hunks.first else { return XCTFail("Expected a diff hunk") }
        XCTAssertEqual(hunk.lines.count, 3)
        let rows = SideBySideDiffBuilder.rows(for: hunk)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first?.left?.kind, .deletion)
        XCTAssertEqual(rows.first?.right?.kind, .addition)
    }

    func testUnifiedDiffParsesCRLFHunkLines() {
        let text = "Index: hello.txt\n"
            + "===================================================================\n"
            + "--- hello.txt\t(revision 1)\n"
            + "+++ hello.txt\t(working copy)\n"
            + "@@ -1,2 +1,2 @@\n"
            + " unchanged\r\n"
            + "-hello\r\n"
            + "+hello world\r\n"

        let lines = UnifiedDiffParser.parse(text).files.first?.hunks.first?.lines

        XCTAssertEqual(lines?.map(\.kind), [.context, .deletion, .addition])
        XCTAssertEqual(lines?.map(\.content), ["unchanged", "hello", "hello world"])
    }

    func testUnifiedDiffSeparatesPropertyChangesFromTextHunk() {
        let text = """
        Index: hello.txt
        ===================================================================
        --- hello.txt\t(revision 1)
        +++ hello.txt\t(working copy)
        @@ -1 +1 @@
        -old
        +new
        Property changes on: hello.txt
        ___________________________________________________________________
        Modified: svn:keywords
        """
        let file = UnifiedDiffParser.parse(text).files.first
        XCTAssertEqual(file?.hunks.first?.lines.count, 2)
        XCTAssertEqual(file?.propertyChanges, [
            "Property changes on: hello.txt",
            "___________________________________________________________________",
            "Modified: svn:keywords"
        ])
    }

    func testUnifiedDiffIgnoresTrailingOutputTerminator() {
        let text = "Index: hello.txt\n--- hello.txt\t(revision 1)\n+++ hello.txt\t(working copy)\n@@ -1 +1 @@\n-old\n+new\n"
        let lines = UnifiedDiffParser.parse(text).files.first?.hunks.first?.lines
        XCTAssertEqual(lines?.map(\.kind), [.deletion, .addition])
    }

    func testPropertyParserPreservesMultilineValue() throws {
        let xml = """
        <?xml version="1.0"?><properties><target path="/tmp/wc/file.txt">
          <property name="svn:keywords">Id Author
        Revision</property><property name="custom:empty"></property>
        </target></properties>
        """
        let properties = try SVNXMLParsers.properties(Data(xml.utf8))
        XCTAssertEqual(properties.map(\.name), ["svn:keywords", "custom:empty"])
        XCTAssertTrue(properties[0].value.contains("Revision"))
    }

    func testStatusParserIncludesLockedOtherwiseCleanFile() throws {
        let xml = """
        <?xml version="1.0"?><status><target path="/tmp/wc">
          <entry path="/tmp/wc/locked.txt"><wc-status item="normal" props="normal" revision="3">
            <lock><token>opaquelocktoken:1</token><owner>alice</owner><comment>Editing</comment><created>2026-08-05T10:15:30.123456Z</created></lock>
          </wc-status></entry>
        </target></status>
        """
        let items = try SVNXMLParsers.status(Data(xml.utf8), workingCopyRoot: URL(fileURLWithPath: "/tmp/wc"))
        XCTAssertEqual(items.first?.lock?.owner, "alice")
        XCTAssertEqual(items.first?.locked, true)
    }
}
