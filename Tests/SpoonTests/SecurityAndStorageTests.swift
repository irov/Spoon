import Foundation
import SpoonDomain
import SpoonSecurity
import SpoonStorage
import XCTest

final class SecurityAndStorageTests: XCTestCase {
    func testRedactorRemovesArgumentsEmbeddedCredentialsAndPrivateKeys() {
        let command = Redactor.command(
            executable: URL(fileURLWithPath: "/app/svn"),
            arguments: ["checkout", "https://alice:secret@example.com/repo", "--password", "hunter2"]
        )
        XCTAssertFalse(command.contains("secret"))
        XCTAssertFalse(command.contains("hunter2"))
        XCTAssertTrue(command.contains("<redacted>"))

        let key = "-----BEGIN PRIVATE KEY-----\nabc123\n-----END PRIVATE KEY-----"
        XCTAssertFalse(Redactor.text(key).contains("abc123"))
    }

    func testSecureTemporaryFileUsesOwnerOnlyPermissions() throws {
        let file = try SecureTemporaryFile(text: "hello", prefix: "test")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.url.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
        file.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path))
    }

    func testSQLiteRoundTripAndMigrations() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SpoonTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteStore(url: directory.appendingPathComponent("test.sqlite"))
        let project = ProjectRecord(displayName: "Example", workingCopyRoot: directory.appendingPathComponent("wc"), isFavorite: true)
        try await store.saveProject(project)
        let projects = try await store.loadProjects()
        XCTAssertEqual(projects.first?.id, project.id)
        XCTAssertEqual(projects.first?.displayName, project.displayName)
        XCTAssertEqual(projects.first?.workingCopyRoot, project.workingCopyRoot)
        XCTAssertEqual(projects.first?.isFavorite, true)
        XCTAssertEqual(projects.first?.lastOpenedAt.timeIntervalSince1970 ?? 0, project.lastOpenedAt.timeIntervalSince1970, accuracy: 0.001)

        let draft = CommitDraft(projectID: project.id, message: "Message", selectedRelativePaths: ["a.txt"])
        try await store.saveDraft(draft)
        let loadedDraft = try await store.loadDraft(projectID: project.id)
        XCTAssertEqual(loadedDraft?.projectID, draft.projectID)
        XCTAssertEqual(loadedDraft?.message, draft.message)
        XCTAssertEqual(loadedDraft?.selectedRelativePaths, draft.selectedRelativePaths)

        let task = TaskRecord(projectID: project.id, operation: .status, targets: [project.workingCopyRoot.path], sanitizedCommand: "svn status")
        try await store.saveTask(task)
        let tasks = try await store.loadTasks(limit: 10)
        XCTAssertEqual(tasks.first?.id, task.id)
    }
}
