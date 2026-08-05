import Foundation
import SpoonDomain

public actor TaskCoordinator {
    public static let shared = TaskCoordinator()
    private var locks: [String: AsyncSemaphore] = [:]

    public init() {}

    public func perform<Value: Sendable>(
        operationClass: SVNOperationClass,
        workingCopyRoot: URL?,
        action: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        guard let workingCopyRoot,
              operationClass == .workingCopyRead || operationClass == .workingCopyWrite else {
            return try await action()
        }

        let key = workingCopyRoot.standardizedFileURL.path
        let lock: AsyncSemaphore
        if let existing = locks[key] {
            lock = existing
        } else {
            let created = AsyncSemaphore(value: 1)
            locks[key] = created
            lock = created
        }

        await lock.wait()
        do {
            let value = try await action()
            await lock.signal()
            return value
        } catch {
            await lock.signal()
            throw error
        }
    }
}

public actor TaskRegistry {
    private var records: [UUID: TaskRecord] = [:]
    private var continuations: [UUID: AsyncStream<[TaskRecord]>.Continuation] = [:]

    public init() {}

    public func updates() -> AsyncStream<[TaskRecord]> {
        let id = UUID()
        let pair = AsyncStream<[TaskRecord]>.makeStream(bufferingPolicy: .bufferingNewest(20))
        continuations[id] = pair.continuation
        pair.continuation.yield(sortedRecords)
        pair.continuation.onTermination = { @Sendable _ in
            Task { await self.removeContinuation(id) }
        }
        return pair.stream
    }

    public func upsert(_ record: TaskRecord) {
        records[record.id] = record
        broadcast()
    }

    public func record(id: UUID) -> TaskRecord? { records[id] }
    public func allRecords() -> [TaskRecord] { sortedRecords }

    public func removeCompleted() {
        records = records.filter { _, record in record.state == .queued || record.state == .running }
        broadcast()
    }

    private var sortedRecords: [TaskRecord] {
        records.values.sorted { $0.createdAt > $1.createdAt }
    }

    private func broadcast() {
        let snapshot = sortedRecords
        for continuation in continuations.values { continuation.yield(snapshot) }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }
}

private actor AsyncSemaphore {
    private var value: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(value: Int) { self.value = value }

    func wait() async {
        if value > 0 {
            value -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signal() {
        if waiters.isEmpty {
            value += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}
