import Foundation

public struct SecurityScopedBookmark: Codable, Hashable, Sendable {
    public let data: Data

    public init(url: URL) throws {
        data = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: [.isDirectoryKey, .fileResourceIdentifierKey],
            relativeTo: nil
        )
    }

    public init(data: Data) {
        self.data = data
    }

    public func resolve() throws -> ResolvedSecurityScope {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return ResolvedSecurityScope(url: url, isStale: isStale)
    }
}

public final class ResolvedSecurityScope: @unchecked Sendable {
    public let url: URL
    public let isStale: Bool
    private let didStartAccessing: Bool

    public init(url: URL, isStale: Bool = false) {
        self.url = url
        self.isStale = isStale
        didStartAccessing = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if didStartAccessing {
            url.stopAccessingSecurityScopedResource()
        }
    }
}
