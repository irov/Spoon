import CoreServices
import Foundation

@MainActor
final class WorkingCopyWatcher {
    nonisolated(unsafe) private var stream: FSEventStreamRef?
    private var debounceTask: Task<Void, Never>?
    private let onChange: @MainActor @Sendable () -> Void

    init(onChange: @escaping @MainActor @Sendable () -> Void) {
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
            Task { @MainActor in
                let containsWorkingFileChange = paths.prefix(count).contains { path in
                    !path.contains("/.svn/") && !path.hasSuffix("/.svn")
                }
                guard containsWorkingFileChange else { return }
                watcher.scheduleDebouncedChange()
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

    private func scheduleDebouncedChange() {
        debounceTask?.cancel()
        debounceTask = Task { [onChange] in
            try? await Task.sleep(for: .milliseconds(550))
            guard !Task.isCancelled else { return }
            onChange()
        }
    }
}
