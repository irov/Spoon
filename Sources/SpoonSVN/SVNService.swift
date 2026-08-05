import Foundation
import SpoonDomain

public actor SVNService {
    public let executor: SVNExecutor
    public let registry: TaskRegistry
    private let coordinator: TaskCoordinator
    private var factory: SVNCommandFactory
    private var authenticationProvider: (@Sendable (SVNAuthenticationChallenge) async throws -> SVNAuthenticationResponse)?

    public init(
        factory: SVNCommandFactory = SVNCommandFactory(),
        executor: SVNExecutor = SVNExecutor(),
        registry: TaskRegistry = TaskRegistry(),
        coordinator: TaskCoordinator = .shared
    ) {
        self.factory = factory
        self.executor = executor
        self.registry = registry
        self.coordinator = coordinator
    }

    public func setAuthenticationProvider(
        _ provider: @escaping @Sendable (SVNAuthenticationChallenge) async throws -> SVNAuthenticationResponse
    ) {
        authenticationProvider = provider
    }

    public func capabilityProbe() async throws -> SVNCapabilitySet {
        try await perform(factory.capabilityProbe(), projectID: nil, workingCopyRoot: nil)
    }

    public func info(path: URL, projectID: UUID? = nil, securityScopedBookmark: Data? = nil) async throws -> WorkingCopyInfo {
        try await perform(factory.info(path: path), projectID: projectID, workingCopyRoot: path, securityScopedBookmark: securityScopedBookmark)
    }

    public func status(project: ProjectRecord, remote: Bool = false, showIgnored: Bool = false) async throws -> [StatusItem] {
        try await perform(
            factory.status(root: project.workingCopyRoot, remote: remote, showIgnored: showIgnored),
            projectID: project.id,
            workingCopyRoot: project.workingCopyRoot,
            securityScopedBookmark: project.workingCopyBookmark
        )
    }

    public func history(project: ProjectRecord, limit: Int = 100, search: String? = nil) async throws -> [RevisionRecord] {
        let target = project.repositoryRootURL?.absoluteString ?? project.workingCopyRoot.path
        return try await perform(factory.log(target: target, limit: limit, search: search), projectID: project.id, workingCopyRoot: nil)
    }

    public func repositoryList(project: ProjectRecord, url: URL, revision: String = "HEAD") async throws -> [RepositoryEntry] {
        try await perform(factory.list(url: url, revision: revision), projectID: project.id, workingCopyRoot: nil)
    }

    public func diff(project: ProjectRecord, paths: [String], revision: String? = nil, change: Int? = nil) async throws -> String {
        try await perform(factory.diff(targets: paths, revision: revision, change: change), projectID: project.id, workingCopyRoot: project.workingCopyRoot, securityScopedBookmark: project.workingCopyBookmark)
    }

    public func blame(project: ProjectRecord, target: String, revision: String? = nil) async throws -> [BlameLine] {
        var lines = try await perform(factory.blame(target: target, revision: revision), projectID: project.id, workingCopyRoot: nil)
        let contents = try await perform(factory.cat(target: target, revision: revision ?? "HEAD"), projectID: project.id, workingCopyRoot: nil)
        let sourceLines = String(decoding: contents, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for index in lines.indices where index < sourceLines.count { lines[index].content = sourceLines[index] }
        return lines
    }

    public func contents(project: ProjectRecord, target: String, revision: String = "HEAD") async throws -> Data {
        try await perform(factory.cat(target: target, revision: revision), projectID: project.id, workingCopyRoot: nil, securityScopedBookmark: project.workingCopyBookmark)
    }

    public func properties(project: ProjectRecord, target: String, revision: String? = nil) async throws -> [SVNPropertyRecord] {
        try await perform(factory.properties(target: target, revision: revision), projectID: project.id, workingCopyRoot: project.workingCopyRoot, securityScopedBookmark: project.workingCopyBookmark)
    }

    public func setProperty(project: ProjectRecord, name: String, value: Data, targets: [String]) async throws -> String {
        try await perform(try factory.propertySet(name: name, value: value, targets: targets), projectID: project.id, workingCopyRoot: project.workingCopyRoot, securityScopedBookmark: project.workingCopyBookmark)
    }

    public func deleteProperty(project: ProjectRecord, name: String, targets: [String]) async throws -> String {
        try await perform(factory.propertyDelete(name: name, targets: targets), projectID: project.id, workingCopyRoot: project.workingCopyRoot, securityScopedBookmark: project.workingCopyBookmark)
    }

    public func checkout(url: URL, destination: URL, revision: String = "HEAD", depth: String = "infinity", ignoreExternals: Bool = false, securityScopedBookmark: Data? = nil) async throws -> String {
        try await perform(factory.checkout(url: url, destination: destination, revision: revision, depth: depth, ignoreExternals: ignoreExternals), projectID: nil, workingCopyRoot: destination, securityScopedBookmark: securityScopedBookmark)
    }

    public func update(project: ProjectRecord, targets: [String]? = nil, revision: String = "HEAD", includeExternals: Bool = true) async throws -> String {
        try await perform(
            factory.update(targets: targets ?? [project.workingCopyRoot.path], revision: revision, includeExternals: includeExternals),
            projectID: project.id,
            workingCopyRoot: project.workingCopyRoot,
            securityScopedBookmark: project.workingCopyBookmark
        )
    }

    public func commit(project: ProjectRecord, targets: [String], message: String) async throws -> Int? {
        try await perform(try factory.commit(targets: targets, message: message), projectID: project.id, workingCopyRoot: project.workingCopyRoot, securityScopedBookmark: project.workingCopyBookmark)
    }

    public func add(project: ProjectRecord, targets: [String]) async throws -> String {
        try await perform(factory.add(targets: targets), projectID: project.id, workingCopyRoot: project.workingCopyRoot, securityScopedBookmark: project.workingCopyBookmark)
    }

    public func delete(project: ProjectRecord, targets: [String], keepLocal: Bool = false) async throws -> String {
        try await perform(factory.delete(targets: targets, keepLocal: keepLocal), projectID: project.id, workingCopyRoot: project.workingCopyRoot, securityScopedBookmark: project.workingCopyBookmark)
    }

    public func move(project: ProjectRecord, source: String, destination: String) async throws -> String {
        try await perform(factory.move(source: source, destination: destination), projectID: project.id, workingCopyRoot: project.workingCopyRoot, securityScopedBookmark: project.workingCopyBookmark)
    }

    public func revert(project: ProjectRecord, targets: [String], depth: String = "empty") async throws -> String {
        try await perform(factory.revert(targets: targets, depth: depth), projectID: project.id, workingCopyRoot: project.workingCopyRoot, securityScopedBookmark: project.workingCopyBookmark)
    }

    public func cleanup(project: ProjectRecord) async throws -> String {
        try await perform(factory.cleanup(root: project.workingCopyRoot), projectID: project.id, workingCopyRoot: project.workingCopyRoot, securityScopedBookmark: project.workingCopyBookmark)
    }

    public func resolve(project: ProjectRecord, targets: [String], choice: ConflictResolution) async throws -> String {
        try await perform(factory.resolve(targets: targets, choice: choice), projectID: project.id, workingCopyRoot: project.workingCopyRoot, securityScopedBookmark: project.workingCopyBookmark)
    }

    public func lock(project: ProjectRecord, targets: [String], message: String? = nil) async throws -> String {
        try await perform(try factory.lock(targets: targets, message: message), projectID: project.id, workingCopyRoot: project.workingCopyRoot, securityScopedBookmark: project.workingCopyBookmark)
    }

    public func unlock(project: ProjectRecord, targets: [String]) async throws -> String {
        try await perform(factory.unlock(targets: targets), projectID: project.id, workingCopyRoot: project.workingCopyRoot, securityScopedBookmark: project.workingCopyBookmark)
    }

    public func setChangelist(project: ProjectRecord, name: String?, targets: [String]) async throws -> String {
        try await perform(factory.changelist(name: name, targets: targets), projectID: project.id, workingCopyRoot: project.workingCopyRoot, securityScopedBookmark: project.workingCopyBookmark)
    }

    public func switchWorkingCopy(project: ProjectRecord, url: URL, revision: String = "HEAD") async throws -> String {
        try await perform(factory.switchWorkingCopy(url: url, path: project.workingCopyRoot, revision: revision), projectID: project.id, workingCopyRoot: project.workingCopyRoot, securityScopedBookmark: project.workingCopyBookmark)
    }

    public func merge(project: ProjectRecord, source: URL, revisionRange: String? = nil, dryRun: Bool = false, reverse: Bool = false) async throws -> String {
        try await perform(factory.merge(source: source, target: project.workingCopyRoot, revisionRange: revisionRange, dryRun: dryRun, reverse: reverse), projectID: project.id, workingCopyRoot: project.workingCopyRoot, securityScopedBookmark: project.workingCopyBookmark)
    }

    public func createRepositoryDirectory(project: ProjectRecord, url: URL, message: String) async throws -> Int? {
        try await perform(try factory.repositoryMkdir(url: url, message: message), projectID: project.id, workingCopyRoot: nil)
    }

    public func repositoryCopy(project: ProjectRecord, source: URL, destination: URL, message: String, revision: String? = nil) async throws -> Int? {
        try await perform(try factory.repositoryCopy(source: source, destination: destination, message: message, revision: revision), projectID: project.id, workingCopyRoot: nil)
    }

    public func repositoryMove(project: ProjectRecord, source: URL, destination: URL, message: String) async throws -> Int? {
        try await perform(try factory.repositoryMove(source: source, destination: destination, message: message), projectID: project.id, workingCopyRoot: nil)
    }

    public func repositoryDelete(project: ProjectRecord, url: URL, message: String) async throws -> Int? {
        try await perform(try factory.repositoryDelete(url: url, message: message), projectID: project.id, workingCopyRoot: nil)
    }

    public func cancel(taskID: UUID) async {
        await executor.cancel(taskID: taskID)
    }

    public func taskUpdates() async -> AsyncStream<[TaskRecord]> {
        await registry.updates()
    }

    private func perform<Output: Sendable>(
        _ descriptor: SVNCommandDescriptor<Output>,
        projectID: UUID?,
        workingCopyRoot: URL?,
        securityScopedBookmark: Data? = nil
    ) async throws -> Output {
        let descriptor = descriptor.withSecurityScopedBookmark(securityScopedBookmark)
        let record = TaskRecord(
            projectID: projectID,
            operation: descriptor.operation,
            targets: descriptor.targets,
            sanitizedCommand: descriptor.sanitizedCommand
        )
        await registry.upsert(record)

        return try await coordinator.perform(
            operationClass: descriptor.operationClass,
            workingCopyRoot: workingCopyRoot
        ) { [self] in
            try await self.runWithAuthentication(descriptor, initialRecord: record)
        }
    }

    private func runWithAuthentication<Output: Sendable>(
        _ descriptor: SVNCommandDescriptor<Output>,
        initialRecord: TaskRecord
    ) async throws -> Output {
        var applied = SVNAuthenticationResponse()
        var attempted = descriptor
        var previousAttemptFailed = false
        for _ in 0..<3 {
            do {
                return try await run(attempted, initialRecord: initialRecord)
            } catch let error as SpoonError {
                guard let challenge = authenticationChallenge(
                    from: error,
                    descriptor: descriptor,
                    previousAttemptFailed: previousAttemptFailed
                ), let authenticationProvider else { throw error }
                let response = try await authenticationProvider(challenge)
                if response.username != nil { applied.username = response.username }
                if response.password != nil { applied.password = response.password }
                applied.saveInKeychain = response.saveInKeychain
                applied.acceptedServerFailures.formUnion(response.acceptedServerFailures)
                attempted = descriptor.applying(authentication: applied)
                previousAttemptFailed = true
            }
        }
        throw SpoonError(title: "Authentication failed", explanation: "The supplied credentials or certificate decision were rejected.", operation: descriptor.operation)
    }

    private func authenticationChallenge<Output: Sendable>(
        from error: SpoonError,
        descriptor: SVNCommandDescriptor<Output>,
        previousAttemptFailed: Bool
    ) -> SVNAuthenticationChallenge? {
        let text = error.explanation
        let target = descriptor.targets.first.flatMap(URL.init(string:))
        let host = target?.host ?? "Subversion server"
        let realm = text.firstMatch(#"Authentication realm:\s*([^\n]+)"#)
        if error.svnCodes.contains(where: { $0.value == "E170001" }) || text.localizedCaseInsensitiveContains("authentication failed") {
            return SVNAuthenticationChallenge(kind: .credentials, host: host, realm: realm, message: text, previousAttemptFailed: previousAttemptFailed)
        }
        if error.svnCodes.contains(where: { $0.value == "E230001" }) || text.localizedCaseInsensitiveContains("certificate verification failed") {
            var failures = Set<String>()
            let lower = text.lowercased()
            if lower.contains("not trusted") || lower.contains("unknown ca") { failures.insert("unknown-ca") }
            if lower.contains("hostname") || lower.contains("cn mismatch") { failures.insert("cn-mismatch") }
            if lower.contains("expired") { failures.insert("expired") }
            if lower.contains("not yet valid") { failures.insert("not-yet-valid") }
            if failures.isEmpty { failures.insert("other") }
            return SVNAuthenticationChallenge(kind: .serverTrust(failures: failures), host: host, realm: realm, message: text, previousAttemptFailed: previousAttemptFailed)
        }
        return nil
    }

    private func run<Output: Sendable>(
        _ descriptor: SVNCommandDescriptor<Output>,
        initialRecord: TaskRecord
    ) async throws -> Output {
        let execution = executor.start(descriptor, taskID: initialRecord.id)
        var running = initialRecord
        running.state = .running
        running.startedAt = .now
        await registry.upsert(running)

        let events = execution.events
        let registry = self.registry
        let runningSnapshot = running
        let eventTask = Task.detached { @Sendable in
            var latest = runningSnapshot
            for await event in events {
                switch event {
                case .stdout(let line), .stderr(let line), .warning(let line), .progress(let line), .authenticationPrompt(let line):
                    latest.summary = line
                    await registry.upsert(latest)
                case .started:
                    break
                }
            }
        }

        do {
            let result = try await execution.result.value
            _ = await eventTask.result
            var completed = running
            completed.state = .succeeded
            completed.finishedAt = .now
            completed.exitCode = result.exitCode
            completed.terminationSignal = result.terminationSignal
            completed.svnErrorCodes = result.svnErrorCodes
            completed.summary = "Completed"
            await registry.upsert(completed)
            return result.output
        } catch is CancellationError {
            eventTask.cancel()
            var cancelled = running
            cancelled.state = .cancelled
            cancelled.finishedAt = .now
            cancelled.summary = "Cancelled"
            await registry.upsert(cancelled)
            throw CancellationError()
        } catch {
            eventTask.cancel()
            var failed = running
            failed.state = .failed
            failed.finishedAt = .now
            failed.summary = error.localizedDescription
            if let spoonError = error as? SpoonError { failed.svnErrorCodes = spoonError.svnCodes }
            await registry.upsert(failed)
            throw error
        }
    }
}

private extension String {
    func firstMatch(_ pattern: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: self, range: NSRange(startIndex..<endIndex, in: self)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: self) else { return nil }
        return String(self[range])
    }
}
