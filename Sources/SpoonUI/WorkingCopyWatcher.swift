import CoreServices
import Foundation

@MainActor
final class WorkingCopyWatcher {
    nonisolated(unsafe) private var stream: FSEventStreamRef?
    private var debounceTask: Task<Void, Never>?
    private var pendingRemoteRefresh = false
    private let onChange: @MainActor @Sendable (_ checkRemote: Bool) -> Void

    init(onChange: @escaping @MainActor @Sendable (_ checkRemote: Bool) -> Void) {
        self.onChange = onChange
    }

    deinit {
        debounceTask?.cancel()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    func watch(_ root: URL?) {
        debounceTask?.cancel()
        pendingRemoteRefresh = false
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        guard let root else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, pathsPointer, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<WorkingCopyWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(pathsPointer, to: NSArray.self) as? [String] ?? []
            var containsWorkingFileChange = false
            var containsSVNMetadataChange = false
            for path in paths.prefix(count) {
                if WorkingCopyWatcher.isSVNMetadataPath(path) {
                    containsSVNMetadataChange = true
                } else {
                    containsWorkingFileChange = true
                }
            }
            Task { @MainActor in
                guard containsWorkingFileChange || containsSVNMetadataChange else { return }
                watcher.scheduleDebouncedChange(checkRemote: containsSVNMetadataChange)
            }
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagWatchRoot |
            kFSEventStreamCreateFlagNoDefer
        )
        guard let created = FSEventStreamCreate(
            nil,
            callback,
            &context,
            [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.35,
            flags
        ) else { return }
        stream = created
        FSEventStreamSetDispatchQueue(created, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(created)
    }

    nonisolated private static func isSVNMetadataPath(_ path: String) -> Bool {
        path.contains("/.svn/") || path.hasSuffix("/.svn")
    }

    private func scheduleDebouncedChange(checkRemote: Bool) {
        pendingRemoteRefresh = pendingRemoteRefresh || checkRemote
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(550))
            guard !Task.isCancelled, let self else { return }
            let checkRemote = self.pendingRemoteRefresh
            self.pendingRemoteRefresh = false
            self.onChange(checkRemote)
        }
    }
}
