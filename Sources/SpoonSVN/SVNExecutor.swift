import Foundation
import SpoonDomain
import SpoonSecurity

public actor SVNExecutor {
    private var activeProcesses: [UUID: Process] = [:]
    private var cancelledTasks = Set<UUID>()

    public init() {}

    public nonisolated func start<Output: Sendable>(
        _ descriptor: SVNCommandDescriptor<Output>,
        taskID: UUID = UUID()
    ) -> SVNExecution<Output> {
        let pair = AsyncStream<SVNCommandEvent>.makeStream(bufferingPolicy: .bufferingNewest(2_000))
        let result = Task {
            try await self.execute(descriptor, taskID: taskID, continuation: pair.continuation)
        }
        pair.continuation.onTermination = { @Sendable _ in
            if result.isCancelled {
                Task { await self.cancel(taskID: taskID) }
            }
        }
        return SVNExecution(taskID: taskID, events: pair.stream, result: result)
    }

    public func cancel(taskID: UUID) async {
        cancelledTasks.insert(taskID)
        guard let process = activeProcesses[taskID], process.isRunning else { return }
        process.interrupt()
        try? await Task.sleep(for: .seconds(2))
        if process.isRunning { process.terminate() }
    }

    private func execute<Output: Sendable>(
        _ descriptor: SVNCommandDescriptor<Output>,
        taskID: UUID,
        continuation: AsyncStream<SVNCommandEvent>.Continuation
    ) async throws -> SVNCommandResult<Output> {
        let clock = ContinuousClock()
        let startedAt = clock.now
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let usesRunner = FileManager.default.isExecutableFile(
            atPath: descriptor.executable.deletingLastPathComponent().appendingPathComponent("svn-core").path
        )
        let stdinPipe = descriptor.standardInput == nil && !usesRunner ? nil : Pipe()

        process.executableURL = descriptor.executable
        process.arguments = descriptor.arguments
        process.currentDirectoryURL = descriptor.workingDirectory
        process.environment = descriptor.environment
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe?.fileHandleForReading ?? FileHandle.nullDevice

        let termination = ProcessTerminationWaiter(process: process)
        do {
            try process.run()
        } catch {
            continuation.finish()
            throw SpoonError(
                title: "Unable to launch Subversion",
                explanation: error.localizedDescription,
                operation: descriptor.operation,
                recoverySuggestion: "Verify the bundled svn executable and its code signature.",
                diagnosticDetails: descriptor.sanitizedCommand
            )
        }

        activeProcesses[taskID] = process
        continuation.yield(.started(processIdentifier: process.processIdentifier))
        if let stdinPipe {
            if usesRunner {
                let bookmark = descriptor.securityScopedBookmark ?? Data()
                var length = UInt32(bookmark.count).bigEndian
                let header = withUnsafeBytes(of: &length) { Data($0) }
                try? stdinPipe.fileHandleForWriting.write(contentsOf: header)
                if !bookmark.isEmpty { try? stdinPipe.fileHandleForWriting.write(contentsOf: bookmark) }
            }
            if let input = descriptor.standardInput {
                try? stdinPipe.fileHandleForWriting.write(contentsOf: input)
            }
            try? stdinPipe.fileHandleForWriting.close()
        }

        async let stdout = Self.read(
            stdoutPipe.fileHandleForReading,
            event: { .stdout($0) },
            continuation: continuation
        )
        async let stderr = Self.read(
            stderrPipe.fileHandleForReading,
            event: { line in
                if line.localizedCaseInsensitiveContains("authentication") || line.localizedCaseInsensitiveContains("password") {
                    return .authenticationPrompt(Redactor.text(line))
                }
                if line.localizedCaseInsensitiveContains("warning") { return .warning(Redactor.text(line)) }
                return .stderr(Redactor.text(line))
            },
            continuation: continuation
        )

        await withTaskCancellationHandler {
            await termination.wait()
        } onCancel: {
            Task { await self.cancel(taskID: taskID) }
        }

        let (stdoutData, stderrData) = try await (stdout, stderr)
        activeProcesses[taskID] = nil
        continuation.finish()

        let stderrText = String(decoding: stderrData, as: UTF8.self)
        let codes = SVNErrorExtractor.codes(in: stderrText)
        let wasCancelled = cancelledTasks.remove(taskID) != nil || Task.isCancelled
        let signal: Int32? = process.terminationReason == .uncaughtSignal ? process.terminationStatus : nil

        if process.terminationStatus != 0 && !wasCancelled {
            throw SpoonError(
                title: "Subversion command failed",
                explanation: Redactor.text(stderrText.isEmpty ? "svn exited with code \(process.terminationStatus)." : stderrText),
                operation: descriptor.operation,
                svnCodes: codes,
                recoverySuggestion: Self.recoverySuggestion(for: codes),
                diagnosticDetails: descriptor.sanitizedCommand
            )
        }

        if wasCancelled {
            throw CancellationError()
        }

        let parsed = try descriptor.parser(stdoutData, stderrData)
        return SVNCommandResult(
            taskID: taskID,
            output: parsed,
            exitCode: process.terminationStatus,
            terminationSignal: signal,
            stdout: stdoutData,
            stderr: stderrData,
            svnErrorCodes: codes,
            wasCancelled: false,
            duration: startedAt.duration(to: clock.now)
        )
    }

    private nonisolated static func read(
        _ handle: FileHandle,
        event: @escaping @Sendable (String) -> SVNCommandEvent,
        continuation: AsyncStream<SVNCommandEvent>.Continuation
    ) async throws -> Data {
        var data = Data()
        for try await line in handle.bytes.lines {
            let sanitized = Redactor.text(line)
            data.append(contentsOf: line.utf8)
            data.append(0x0A)
            continuation.yield(event(sanitized))
        }
        return data
    }

    private static func recoverySuggestion(for codes: [SVNErrorCode]) -> String? {
        let values = Set(codes.map(\.value))
        if values.contains("E155004") { return "Run the safe working-copy cleanup flow, then refresh status." }
        if values.contains("E155036") { return "Review the working-copy upgrade warning and upgrade explicitly if appropriate." }
        if values.contains("E170001") { return "Check the saved credential profile and authenticate again." }
        if values.contains("E155015") { return "Resolve the selected conflicts before committing." }
        return nil
    }
}

private final class ProcessTerminationWaiter: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var terminated = false

    init(process: Process) {
        self.process = process
        process.terminationHandler = { [weak self] _ in self?.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if terminated {
                lock.unlock()
                continuation.resume()
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    private func resume() {
        lock.lock()
        terminated = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}
