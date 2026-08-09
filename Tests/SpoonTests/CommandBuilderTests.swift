import Foundation
import Darwin
import SpoonDomain
import SpoonSVN
import XCTest

final class CommandBuilderTests: XCTestCase {
    func testPathsRemainDistinctArgumentsAndNoShellIsUsed() {
        let factory = SVNCommandFactory(
            executable: URL(fileURLWithPath: "/usr/bin/svn"),
            configDirectory: URL(fileURLWithPath: "/tmp/spoon config")
        )
        let descriptor = factory.status(root: URL(fileURLWithPath: "/tmp/working copy"), remote: true, showIgnored: true)
        XCTAssertEqual(descriptor.executable.path, "/usr/bin/svn")
        XCTAssertTrue(descriptor.arguments.contains("/tmp/working copy"))
        XCTAssertFalse(descriptor.arguments.contains("sh"))
        XCTAssertFalse(descriptor.arguments.contains("-c"))
    }

    func testSVNSSHUsesSystemExecutableAndSpoonConfiguration() {
        let factory = SVNCommandFactory(
            executable: URL(fileURLWithPath: "/usr/bin/svn"),
            configDirectory: URL(fileURLWithPath: "/tmp/spoon config")
        )

        let descriptor = factory.list(url: URL(string: "svn+ssh://example.com/repository")!)

        XCTAssertEqual(
            descriptor.environment["SVN_SSH"],
            "\"/usr/bin/ssh\" -F \"/tmp/spoon config/ssh/config\""
        )
    }

    func testCommitUsesOwnerOnlyMessageAndTargetsFiles() throws {
        let factory = SVNCommandFactory(executable: URL(fileURLWithPath: "/usr/bin/svn"), configDirectory: URL(fileURLWithPath: "/tmp/config"))
        let descriptor = try factory.commit(targets: ["/tmp/a file", "/tmp/-leading-dash"], message: "Unicode ✓ ' \" $(touch nope)")
        XCTAssertTrue(descriptor.arguments.contains("--file"))
        XCTAssertTrue(descriptor.arguments.contains("--targets"))
        guard let depthIndex = descriptor.arguments.firstIndex(of: "--depth") else {
            return XCTFail("Expected a non-recursive commit depth")
        }
        XCTAssertEqual(descriptor.arguments[depthIndex + 1], "empty")
        XCTAssertEqual(descriptor.retainedResources.count, 2)
        XCTAssertFalse(descriptor.sanitizedCommand.contains("Unicode ✓"))
        for resource in descriptor.retainedResources {
            let attributes = try FileManager.default.attributesOfItem(atPath: resource.url.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0, 0o600)
        }
    }

    func testFullFileDiffUsesInternalSVNContextOption() {
        let factory = SVNCommandFactory(
            executable: URL(fileURLWithPath: "/usr/bin/svn"),
            configDirectory: URL(fileURLWithPath: "/tmp/config")
        )
        let descriptor = factory.diff(targets: ["/tmp/file.swift"], contextLines: Int(Int32.max))
        guard let extensionIndex = descriptor.arguments.firstIndex(of: "-x") else {
            return XCTFail("Expected the internal diff extension option")
        }
        XCTAssertEqual(descriptor.arguments[extensionIndex + 1], "-U 2147483647")
        XCTAssertEqual(descriptor.arguments.suffix(2), ["--", "/tmp/file.swift"])
    }

    func testDiffCanSelectTextOrPropertyChanges() {
        let factory = SVNCommandFactory(
            executable: URL(fileURLWithPath: "/usr/bin/svn"),
            configDirectory: URL(fileURLWithPath: "/tmp/config")
        )

        let text = factory.diff(targets: ["/tmp/file.swift"], content: .textOnly)
        XCTAssertTrue(text.arguments.contains("--ignore-properties"))
        XCTAssertFalse(text.arguments.contains("--properties-only"))

        let properties = factory.diff(targets: ["/tmp"], content: .propertiesOnly, depth: "empty")
        XCTAssertTrue(properties.arguments.contains("--properties-only"))
        XCTAssertEqual(properties.arguments.suffix(4), ["--depth", "empty", "--", "/tmp"])
    }

    func testSVNErrorCodesAreStructuredAndDeduplicated() {
        let codes = SVNErrorExtractor.codes(in: "svn: E155004 locked\nsvn: E170001 auth\nsvn: E155004 again")
        XCTAssertEqual(codes.map(\.value), ["E155004", "E170001"])
    }

    func testInfoForNonWorkingCopyReturnsFriendlyError() async {
        let descriptor = SVNCommandDescriptor<Data>(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo \"svn: E155007: '/tmp/example' is not a working copy\" >&2; exit 1"],
            operation: .info,
            operationClass: .workingCopyRead
        ) { stdout, _ in stdout }

        do {
            _ = try await SVNExecutor().start(descriptor).result.value
            XCTFail("Expected a non-working-copy error")
        } catch let error as SpoonError {
            XCTAssertEqual(error.title, "This Isn't an SVN Working Copy")
            XCTAssertTrue(error.explanation.contains("Nothing was changed."))
            XCTAssertFalse(error.explanation.contains("svn:"))
            XCTAssertEqual(error.svnCodes.map(\.value), ["E155007"])
            XCTAssertNil(error.diagnosticDetails)
        } catch {
            XCTFail("Expected SpoonError, got \(error)")
        }
    }

    func testAuthenticationUsesStandardInputAndNeverCommandOrEnvironment() {
        let factory = SVNCommandFactory(executable: URL(fileURLWithPath: "/usr/bin/svn"), configDirectory: URL(fileURLWithPath: "/tmp/config"))
        let descriptor = factory.list(url: URL(string: "https://example.com/repository")!)
            .applying(authentication: SVNAuthenticationResponse(username: "alice", password: "very-secret"))
        XCTAssertTrue(descriptor.arguments.contains("--password-from-stdin"))
        XCTAssertFalse(descriptor.arguments.contains("very-secret"))
        XCTAssertFalse(descriptor.environment.values.contains("very-secret"))
        XCTAssertFalse(descriptor.sanitizedCommand.contains("very-secret"))
        XCTAssertEqual(String(data: descriptor.standardInput ?? Data(), encoding: .utf8), "very-secret\n")
    }

    func testCommitAuthenticationUsesProjectRepositoryHost() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpoonAuthentication-\(UUID().uuidString)", isDirectory: true)
        let executable = root.appendingPathComponent("fake-svn")
        let config = root.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("""
        #!/bin/sh
        echo "svn: E170013: Unable to connect to a repository at URL 'https://wrong.example/repository/path'" >&2
        echo "svn: E230001: Server SSL certificate verification failed: issuer is not trusted" >&2
        exit 1
        """.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let service = SVNService(factory: SVNCommandFactory(executable: executable, configDirectory: config))
        let recorder = AuthenticationChallengeRecorder()
        await service.setAuthenticationProvider { challenge in
            await recorder.record(host: challenge.host)
            throw CancellationError()
        }
        let project = ProjectRecord(
            displayName: "Example",
            workingCopyRoot: root.appendingPathComponent("working-copy"),
            repositoryRootURL: URL(string: "https://svn.example.com/repository")
        )

        do {
            _ = try await service.commit(project: project, targets: ["/tmp/file"], message: "Test")
            XCTFail("Expected the authentication flow to stop")
        } catch is CancellationError {
            // Expected after recording the challenge.
        }

        let host = await recorder.host
        XCTAssertEqual(host, "svn.example.com")
    }

    func testCancellationInterruptsThenTerminatesProcess() async throws {
        let descriptor = SVNCommandDescriptor<String>(
            executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["10"],
            operation: .status,
            operationClass: .repositoryRead
        ) { _, _ in "unexpected" }
        let executor = SVNExecutor()
        let execution = executor.start(descriptor)
        try await Task.sleep(for: .milliseconds(150))
        await executor.cancel(taskID: execution.taskID)
        do {
            _ = try await execution.result.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testExecutorReportsHelperSignalWithoutCallingItAnExitCode() async {
        let descriptor = SVNCommandDescriptor<Data>(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "kill -TRAP $$"],
            operation: .log,
            operationClass: .repositoryRead
        ) { stdout, _ in stdout }

        do {
            _ = try await SVNExecutor().start(descriptor).result.value
            XCTFail("Expected the helper process to stop with SIGTRAP")
        } catch let error as SpoonError {
            XCTAssertEqual(error.title, "Subversion helper stopped unexpectedly")
            XCTAssertEqual(error.terminationSignal, SIGTRAP)
            XCTAssertFalse(error.explanation.contains("exited with code"))
        } catch {
            XCTFail("Expected SpoonError, got \(error)")
        }
    }

    func testExecutorDrainsOutputLargerThanPipeCapacity() async throws {
        let descriptor = SVNCommandDescriptor<Data>(
            executable: URL(fileURLWithPath: "/usr/bin/jot"),
            arguments: ["100000", "1"],
            operation: .status,
            operationClass: .repositoryRead
        ) { stdout, _ in stdout }

        let result = try await SVNExecutor().start(descriptor).result.value

        XCTAssertGreaterThan(result.output.count, 256_000)
        XCTAssertTrue(String(decoding: result.output.suffix(8), as: UTF8.self).contains("100000"))
    }

    func testOnlyScheduledLocalChangesAreCommitEligible() {
        XCTAssertTrue(statusItem(workingCopyStatus: .modified).isCommitEligible)
        XCTAssertTrue(statusItem(workingCopyStatus: .added).isCommitEligible)
        XCTAssertTrue(statusItem(workingCopyStatus: .deleted).isCommitEligible)
        XCTAssertTrue(statusItem(workingCopyStatus: .normal, propertyStatus: .modified).isCommitEligible)

        XCTAssertFalse(statusItem(workingCopyStatus: .unversioned).isCommitEligible)
        XCTAssertFalse(statusItem(workingCopyStatus: .ignored).isCommitEligible)
        XCTAssertFalse(statusItem(workingCopyStatus: .missing).isCommitEligible)
        XCTAssertFalse(statusItem(workingCopyStatus: .conflicted).isCommitEligible)
        XCTAssertFalse(statusItem(workingCopyStatus: .modified, treeConflicted: true).isCommitEligible)

        XCTAssertTrue(statusItem(workingCopyStatus: .modified).isStageable)
        XCTAssertTrue(statusItem(workingCopyStatus: .unversioned).isStageable)
        XCTAssertFalse(statusItem(workingCopyStatus: .ignored).isStageable)
        XCTAssertFalse(statusItem(workingCopyStatus: .missing).isStageable)
        XCTAssertFalse(statusItem(workingCopyStatus: .conflicted).isStageable)
    }

    func testDirectoryStagingSelectionIncludesAllDescendants() {
        let items = [
            statusItem(relativePath: "StoreAssets", nodeKind: .directory, workingCopyStatus: .added),
            statusItem(relativePath: "StoreAssets/README.md", workingCopyStatus: .added),
            statusItem(relativePath: "StoreAssets/iPad-13", nodeKind: .directory, workingCopyStatus: .added),
            statusItem(relativePath: "StoreAssets/iPad-13/01-gameplay.png", workingCopyStatus: .added),
            statusItem(relativePath: "StoreAssetsBackup/image.png", workingCopyStatus: .added),
        ]

        let selected = StatusItem.expandingSelection(["StoreAssets"], in: items)

        XCTAssertEqual(
            Set(selected.map(\.relativePath)),
            [
                "StoreAssets",
                "StoreAssets/README.md",
                "StoreAssets/iPad-13",
                "StoreAssets/iPad-13/01-gameplay.png",
            ]
        )
    }

    func testAddingSVNIgnoreRulePreservesExistingPatternsAndAvoidsDuplicates() {
        let existing = "*.profraw\nbuild\n"
        let updated = SVNIgnoreProperty.adding(pattern: "workspace.code-workspace", to: existing)

        XCTAssertEqual(updated, "*.profraw\nbuild\nworkspace.code-workspace\n")
        XCTAssertEqual(SVNIgnoreProperty.adding(pattern: "build", to: updated), updated)
        XCTAssertEqual(SVNIgnoreProperty.adding(pattern: "file.txt", to: "*.tmp"), "*.tmp\nfile.txt\n")
        XCTAssertEqual(SVNIgnoreProperty.adding(pattern: "DerivedData", to: "*.xcuserstate\r\n"), "*.xcuserstate\r\nDerivedData\r\n")
        XCTAssertEqual(SVNIgnoreProperty.extensionPattern(forFileName: "report.log"), "*.log")
        XCTAssertEqual(SVNIgnoreProperty.extensionPattern(forFileName: "archive.tar.gz"), "*.gz")
        XCTAssertNil(SVNIgnoreProperty.extensionPattern(forFileName: "Makefile"))
        XCTAssertNil(SVNIgnoreProperty.extensionPattern(forFileName: ".gitignore"))
    }

    private func statusItem(
        relativePath: String = "path.txt",
        nodeKind: NodeKind = .unknown,
        workingCopyStatus: WorkingCopyStatus,
        propertyStatus: WorkingCopyStatus = .none,
        treeConflicted: Bool = false
    ) -> StatusItem {
        StatusItem(
            relativePath: relativePath,
            absolutePath: URL(fileURLWithPath: "/tmp").appendingPathComponent(relativePath),
            nodeKind: nodeKind,
            workingCopyStatus: workingCopyStatus,
            propertyStatus: propertyStatus,
            treeConflicted: treeConflicted
        )
    }
}

private actor AuthenticationChallengeRecorder {
    private(set) var host: String?

    func record(host: String) {
        self.host = host
    }
}
