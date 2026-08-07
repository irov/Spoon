import Foundation
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

    func testCommitUsesOwnerOnlyMessageAndTargetsFiles() throws {
        let factory = SVNCommandFactory(executable: URL(fileURLWithPath: "/usr/bin/svn"), configDirectory: URL(fileURLWithPath: "/tmp/config"))
        let descriptor = try factory.commit(targets: ["/tmp/a file", "/tmp/-leading-dash"], message: "Unicode ✓ ' \" $(touch nope)")
        XCTAssertTrue(descriptor.arguments.contains("--file"))
        XCTAssertTrue(descriptor.arguments.contains("--targets"))
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

    func testSVNErrorCodesAreStructuredAndDeduplicated() {
        let codes = SVNErrorExtractor.codes(in: "svn: E155004 locked\nsvn: E170001 auth\nsvn: E155004 again")
        XCTAssertEqual(codes.map(\.value), ["E155004", "E170001"])
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
    }

    private func statusItem(
        workingCopyStatus: WorkingCopyStatus,
        propertyStatus: WorkingCopyStatus = .none,
        treeConflicted: Bool = false
    ) -> StatusItem {
        StatusItem(
            relativePath: "path.txt",
            absolutePath: URL(fileURLWithPath: "/tmp/path.txt"),
            workingCopyStatus: workingCopyStatus,
            propertyStatus: propertyStatus,
            treeConflicted: treeConflicted
        )
    }
}
