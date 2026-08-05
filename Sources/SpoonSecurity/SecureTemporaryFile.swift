import Darwin
import Foundation

public final class SecureTemporaryFile: @unchecked Sendable {
    public let url: URL
    private let removeOnDeinit: Bool

    public init(data: Data, prefix: String, suffix: String = "", removeOnDeinit: Bool = true) throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("Spoon", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        url = base.appendingPathComponent("\(prefix)-\(UUID().uuidString)\(suffix)")
        guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        _ = chmod(url.path, S_IRUSR | S_IWUSR)
        self.removeOnDeinit = removeOnDeinit
    }

    public convenience init(text: String, prefix: String, suffix: String = ".txt", removeOnDeinit: Bool = true) throws {
        try self.init(data: Data(text.utf8), prefix: prefix, suffix: suffix, removeOnDeinit: removeOnDeinit)
    }

    public func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    deinit {
        if removeOnDeinit { remove() }
    }

    public static func removeAbandonedFiles(olderThan age: TimeInterval = 24 * 60 * 60) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("Spoon", isDirectory: true)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: base,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let deadline = Date().addingTimeInterval(-age)
        for file in contents {
            let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if modified.map({ $0 < deadline }) ?? true {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
