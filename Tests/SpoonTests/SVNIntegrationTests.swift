import Foundation
import SpoonDomain
import SpoonSecurity
import SpoonSVN
import XCTest

final class SVNIntegrationTests: XCTestCase {
    func testCheckoutCreatesMissingWorkingCopyFolderUsingParentPermission() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpoonCheckoutPermission-\(UUID().uuidString)", isDirectory: true)
        let repository = root.appendingPathComponent("repository", isDirectory: true)
        let destinationParent = root.appendingPathComponent("checkouts", isDirectory: true)
        let destination = destinationParent.appendingPathComponent("Example Project", isDirectory: true)
        let config = root.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationParent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try run(URL(fileURLWithPath: "/opt/homebrew/bin/svnadmin"), ["create", repository.path])
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))

        let service = SVNService(factory: SVNCommandFactory(executable: bundledSVN, configDirectory: config))
        let parentBookmark = try SecurityScopedBookmark(url: destinationParent).data
        _ = try await service.checkout(
            url: repository.absoluteURL,
            destination: destination,
            securityScopedBookmark: parentBookmark
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        let info = try await service.info(path: destination, securityScopedBookmark: parentBookmark)
        XCTAssertEqual(info.workingCopyRoot.standardizedFileURL, destination.standardizedFileURL)
    }

    func testDisposableRepositoryWorkingCopyLifecycle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SpoonIntegration-\(UUID().uuidString)", isDirectory: true)
        let repository = root.appendingPathComponent("repository", isDirectory: true)
        let workingCopy = root.appendingPathComponent("working copy", isDirectory: true)
        let config = root.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try run(URL(fileURLWithPath: "/opt/homebrew/bin/svnadmin"), ["create", repository.path])
        let repositoryURL = URL(fileURLWithPath: repository.path).absoluteURL
        let service = SVNService(factory: SVNCommandFactory(executable: bundledSVN, configDirectory: config))
        _ = try await service.checkout(url: repositoryURL, destination: workingCopy)

        let file = workingCopy.appendingPathComponent("hello world.txt")
        try Data("first\n".utf8).write(to: file)
        var info = try await service.info(path: workingCopy)
        var project = ProjectRecord(
            displayName: "Integration",
            workingCopyRoot: workingCopy,
            repositoryRootURL: info.repositoryRootURL,
            repositoryUUID: info.repositoryUUID,
            relativeURL: info.relativeURL
        )
        _ = try await service.add(project: project, targets: [file.path])
        let message = "Initial ✓ ' \" $() commit"
        let revision = try await service.commit(project: project, targets: [file.path], message: message)
        XCTAssertEqual(revision, 1)

        try Data("first\nsecond\n".utf8).write(to: file)
        let status = try await service.status(project: project)
        XCTAssertEqual(status.first?.workingCopyStatus, .modified)
        let diff = try await service.diff(project: project, paths: [file.path])
        XCTAssertTrue(diff.contains("+second"))
        let history = try await service.history(project: project, limit: 10)
        XCTAssertEqual(history.first?.revision, 1)
        XCTAssertEqual(history.first?.message, message)

        _ = try await service.revert(project: project, targets: [file.path])
        let cleanStatus = try await service.status(project: project)
        XCTAssertTrue(cleanStatus.isEmpty)
        _ = try await service.update(project: project, targets: [workingCopy.path])

        try Data("unrelated local edit\n".utf8).write(to: file)
        let ignoredFile = workingCopy.appendingPathComponent("generated.profraw")
        try Data("profile\n".utf8).write(to: ignoredFile)
        _ = try await service.setProperty(
            project: project,
            name: "svn:ignore",
            value: Data("generated.profraw\n".utf8),
            targets: [workingCopy.path]
        )

        let ignoreStatus = try await service.status(project: project)
        XCTAssertTrue(ignoreStatus.contains(where: { $0.relativePath == "." && $0.propertyStatus == .modified }))
        XCTAssertTrue(ignoreStatus.contains(where: { $0.relativePath == "hello world.txt" && $0.workingCopyStatus == .modified }))
        XCTAssertFalse(ignoreStatus.contains(where: { $0.relativePath == "generated.profraw" }))

        let propertyRevision = try await service.commit(
            project: project,
            targets: [workingCopy.path],
            message: "Ignore generated file"
        )
        XCTAssertEqual(propertyRevision, 2)

        let afterPropertyCommit = try await service.status(project: project)
        XCTAssertTrue(afterPropertyCommit.contains(where: { $0.relativePath == "hello world.txt" && $0.workingCopyStatus == .modified }))
        XCTAssertFalse(afterPropertyCommit.contains(where: { $0.relativePath == "." }))
        XCTAssertFalse(afterPropertyCommit.contains(where: { $0.relativePath == "generated.profraw" }))
        let statusIncludingIgnored = try await service.status(project: project, showIgnored: true)
        XCTAssertTrue(statusIncludingIgnored.contains(where: { $0.relativePath == "generated.profraw" && $0.workingCopyStatus == .ignored }))

        _ = try await service.revert(project: project, targets: [file.path])

        info = try await service.info(path: workingCopy)
        project.repositoryRootURL = info.repositoryRootURL
        XCTAssertEqual(info.revision, 2)
    }

    func testScheduledDirectoryAdditionCanBeRevertedAndIgnoredWithoutDeletingFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SpoonIgnoreIntegration-\(UUID().uuidString)", isDirectory: true)
        let repository = root.appendingPathComponent("repository", isDirectory: true)
        let workingCopy = root.appendingPathComponent("working-copy", isDirectory: true)
        let config = root.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try run(URL(fileURLWithPath: "/opt/homebrew/bin/svnadmin"), ["create", repository.path])
        let service = SVNService(factory: SVNCommandFactory(executable: bundledSVN, configDirectory: config))
        _ = try await service.checkout(url: repository.absoluteURL, destination: workingCopy)

        let info = try await service.info(path: workingCopy)
        let project = ProjectRecord(
            displayName: "Ignore integration",
            workingCopyRoot: workingCopy,
            repositoryRootURL: info.repositoryRootURL,
            repositoryUUID: info.repositoryUUID,
            relativeURL: info.relativeURL
        )
        let generatedDirectory = workingCopy.appendingPathComponent("generated", isDirectory: true)
        let generatedFile = generatedDirectory.appendingPathComponent("output.txt")
        try FileManager.default.createDirectory(at: generatedDirectory, withIntermediateDirectories: true)
        try Data("generated\n".utf8).write(to: generatedFile)

        _ = try await service.add(project: project, targets: [generatedDirectory.path])
        let addedStatus = try await service.status(project: project)
        XCTAssertTrue(addedStatus.contains(where: {
            $0.relativePath == "generated" && $0.workingCopyStatus == .added
        }))
        XCTAssertTrue(addedStatus.contains(where: {
            $0.relativePath == "generated/output.txt" && $0.workingCopyStatus == .added
        }))

        _ = try await service.setProperty(
            project: project,
            name: "svn:ignore",
            value: Data("generated\n".utf8),
            targets: [workingCopy.path]
        )
        _ = try await service.revert(project: project, targets: [generatedDirectory.path], depth: "infinity")

        XCTAssertTrue(FileManager.default.fileExists(atPath: generatedDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: generatedFile.path))
        let ignoredStatus = try await service.status(project: project, showIgnored: true)
        XCTAssertTrue(ignoredStatus.contains(where: {
            $0.relativePath == "generated" && $0.workingCopyStatus == .ignored
        }))
        XCTAssertFalse(ignoredStatus.contains(where: {
            $0.relativePath == "generated/output.txt" && $0.workingCopyStatus == .added
        }))
    }

    func testAtSignPathCanBeAddedCommittedAndDiffed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SpoonPegIntegration-\(UUID().uuidString)", isDirectory: true)
        let repository = root.appendingPathComponent("repository", isDirectory: true)
        let workingCopy = root.appendingPathComponent("working-copy", isDirectory: true)
        let config = root.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try run(URL(fileURLWithPath: "/opt/homebrew/bin/svnadmin"), ["create", repository.path])
        let service = SVNService(factory: SVNCommandFactory(executable: bundledSVN, configDirectory: config))
        _ = try await service.checkout(url: repository.absoluteURL, destination: workingCopy)

        let info = try await service.info(path: workingCopy)
        let project = ProjectRecord(
            displayName: "Peg integration",
            workingCopyRoot: workingCopy,
            repositoryRootURL: info.repositoryRootURL,
            repositoryUUID: info.repositoryUUID,
            relativeURL: info.relativeURL
        )
        let asset = workingCopy.appendingPathComponent("Icon-20x20@1x.png")
        try Data("first\n".utf8).write(to: asset)

        _ = try await service.add(project: project, targets: [asset.path])
        let revision = try await service.commit(project: project, targets: [asset.path], message: "Add icon")
        XCTAssertEqual(revision, 1)
        let cleanStatus = try await service.status(project: project)
        XCTAssertTrue(cleanStatus.isEmpty)

        try Data("first\nsecond\n".utf8).write(to: asset)
        let diff = try await service.diff(project: project, paths: [asset.path])
        XCTAssertTrue(diff.contains("+second"))
    }

    func testBundledToolchainRepositoryMutationsPropertiesLocksSwitchAndMerge() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SpoonServerIntegration-\(UUID().uuidString)", isDirectory: true)
        let repository = root.appendingPathComponent("repository", isDirectory: true)
        let workingCopy = root.appendingPathComponent("working-copy", isDirectory: true)
        let config = root.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try run(URL(fileURLWithPath: "/opt/homebrew/bin/svnadmin"), ["create", repository.path])

        let repositoryURL = URL(fileURLWithPath: repository.path).absoluteURL
        let trunk = repositoryURL.appendingPathComponent("trunk")
        let branches = repositoryURL.appendingPathComponent("branches")
        let service = SVNService(factory: SVNCommandFactory(executable: bundledSVN, configDirectory: config))
        let seedProject = ProjectRecord(displayName: "Seed", workingCopyRoot: workingCopy)
        _ = try await service.createRepositoryDirectory(project: seedProject, url: trunk, message: "Create trunk")
        _ = try await service.createRepositoryDirectory(project: seedProject, url: branches, message: "Create branches")
        _ = try await service.checkout(url: trunk, destination: workingCopy)

        let info = try await service.info(path: workingCopy)
        let project = ProjectRecord(
            displayName: "Server operations",
            workingCopyRoot: workingCopy,
            repositoryRootURL: info.repositoryRootURL,
            repositoryUUID: info.repositoryUUID,
            relativeURL: info.relativeURL
        )
        let file = workingCopy.appendingPathComponent("merge.txt")
        try Data("trunk\n".utf8).write(to: file)
        _ = try await service.add(project: project, targets: [file.path])
        _ = try await service.commit(project: project, targets: [file.path], message: "Add merge fixture")

        _ = try await service.setProperty(project: project, name: "spoon:test", value: Data("value\n".utf8), targets: [file.path])
        let properties = try await service.properties(project: project, target: file.path)
        XCTAssertEqual(properties.first(where: { $0.name == "spoon:test" })?.value, "value\n")
        let propertyDiff = try await service.diff(
            project: project,
            paths: [file.path],
            content: .propertiesOnly,
            depth: "empty"
        )
        XCTAssertTrue(propertyDiff.contains("Property changes on:"))
        XCTAssertTrue(propertyDiff.contains("spoon:test"))
        _ = try await service.revert(project: project, targets: [file.path])

        _ = try await service.lock(project: project, targets: [file.path], message: "Spoon lock")
        let lockedStatus = try await service.status(project: project)
        XCTAssertTrue(lockedStatus.contains(where: { $0.locked }))
        _ = try await service.unlock(project: project, targets: [file.path])

        let feature = branches.appendingPathComponent("feature")
        _ = try await service.repositoryCopy(project: project, source: trunk, destination: feature, message: "Create feature")
        _ = try await service.switchWorkingCopy(project: project, url: feature)
        try Data("trunk\nfeature\n".utf8).write(to: file)
        _ = try await service.commit(project: project, targets: [file.path], message: "Feature edit")
        _ = try await service.switchWorkingCopy(project: project, url: trunk)
        let preview = try await service.merge(project: project, source: feature, dryRun: true)
        XCTAssertTrue(preview.contains("merge.txt"))
        _ = try await service.merge(project: project, source: feature)
        let mergedStatus = try await service.status(project: project)
        XCTAssertTrue(mergedStatus.contains(where: { $0.workingCopyStatus == .modified }))
        _ = try await service.revert(project: project, targets: [file.path])

        let renamed = branches.appendingPathComponent("renamed")
        _ = try await service.repositoryMove(project: project, source: feature, destination: renamed, message: "Rename branch")
        let afterRename = try await service.repositoryList(project: project, url: branches)
        XCTAssertTrue(afterRename.contains(where: { $0.name == "renamed" }))
        _ = try await service.repositoryDelete(project: project, url: renamed, message: "Delete branch")
        let afterDelete = try await service.repositoryList(project: project, url: branches)
        XCTAssertFalse(afterDelete.contains(where: { $0.name == "renamed" }))
    }

    private var bundledSVN: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Vendor/Toolchain/Helpers/svn-core")
    }

    private func run(_ executable: URL, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw NSError(domain: "SVNIntegrationTests", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
