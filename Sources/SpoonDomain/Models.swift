import Foundation

public enum ProjectSection: String, CaseIterable, Codable, Sendable, Identifiable {
    case localChanges
    case history
    case repository
    case branchesAndTags
    case changelists
    case conflicts
    case tasks

    public var id: String { rawValue }
}

public struct ProjectRecord: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var displayName: String
    public var workingCopyRoot: URL
    public var workingCopyBookmark: Data?
    public var repositoryRootURL: URL?
    public var repositoryUUID: String?
    public var relativeURL: String?
    public var groupID: UUID?
    public var isFavorite: Bool
    public var lastOpenedAt: Date
    public var settingsOverride: ProjectSettings?

    public init(
        id: UUID = UUID(),
        displayName: String,
        workingCopyRoot: URL,
        workingCopyBookmark: Data? = nil,
        repositoryRootURL: URL? = nil,
        repositoryUUID: String? = nil,
        relativeURL: String? = nil,
        groupID: UUID? = nil,
        isFavorite: Bool = false,
        lastOpenedAt: Date = .now,
        settingsOverride: ProjectSettings? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.workingCopyRoot = workingCopyRoot
        self.workingCopyBookmark = workingCopyBookmark
        self.repositoryRootURL = repositoryRootURL
        self.repositoryUUID = repositoryUUID
        self.relativeURL = relativeURL
        self.groupID = groupID
        self.isFavorite = isFavorite
        self.lastOpenedAt = lastOpenedAt
        self.settingsOverride = settingsOverride
    }
}

public struct ProjectGroup: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var sortIndex: Int

    public init(id: UUID = UUID(), name: String, sortIndex: Int = 0) {
        self.id = id
        self.name = name
        self.sortIndex = sortIndex
    }
}

public struct ProjectSettings: Codable, Hashable, Sendable {
    public var includeExternalsOnUpdate: Bool
    public var showIgnored: Bool
    public var diffLayout: DiffLayout
    public var ignoreWhitespace: Bool

    public init(
        includeExternalsOnUpdate: Bool = true,
        showIgnored: Bool = false,
        diffLayout: DiffLayout = .sideBySide,
        ignoreWhitespace: Bool = false
    ) {
        self.includeExternalsOnUpdate = includeExternalsOnUpdate
        self.showIgnored = showIgnored
        self.diffLayout = diffLayout
        self.ignoreWhitespace = ignoreWhitespace
    }
}

public enum DiffLayout: String, Codable, CaseIterable, Sendable {
    case unified
    case sideBySide
}

public enum NodeKind: String, Codable, Sendable {
    case file
    case directory = "dir"
    case symbolicLink
    case unknown
}

public enum WorkingCopyStatus: String, Codable, CaseIterable, Sendable {
    case none
    case normal
    case modified
    case added
    case deleted
    case missing
    case replaced
    case conflicted
    case obstructed
    case unversioned
    case ignored
    case external
    case incomplete
    case merged
    case unknown

    public init(svnValue: String) {
        self = Self(rawValue: svnValue) ?? .unknown
    }
}

public enum RemoteStatus: String, Codable, Sendable {
    case none
    case normal
    case modified
    case added
    case deleted
    case replaced
    case unknown

    public init(svnValue: String?) {
        guard let svnValue else { self = .none; return }
        self = Self(rawValue: svnValue) ?? .unknown
    }
}

public struct LockRecord: Codable, Hashable, Sendable {
    public var token: String?
    public var owner: String?
    public var comment: String?
    public var createdAt: Date?

    public init(token: String? = nil, owner: String? = nil, comment: String? = nil, createdAt: Date? = nil) {
        self.token = token
        self.owner = owner
        self.comment = comment
        self.createdAt = createdAt
    }
}

public struct SVNPropertyRecord: Codable, Hashable, Identifiable, Sendable {
    public var id: String { name }
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public enum SVNIgnoreProperty {
    public static func extensionPattern(forFileName fileName: String) -> String? {
        let pathExtension = URL(fileURLWithPath: fileName).pathExtension
        guard !pathExtension.isEmpty else { return nil }
        return "*.\(pathExtension)"
    }

    public static func adding(pattern: String, to existingValue: String) -> String {
        guard !pattern.isEmpty, !pattern.contains(where: \.isNewline) else { return existingValue }
        let existingPatterns = existingValue
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        guard !existingPatterns.contains(pattern) else { return existingValue }

        let newline = existingValue.contains("\r\n") ? "\r\n" : "\n"
        var updatedValue = existingValue
        if !updatedValue.isEmpty, updatedValue.last?.isNewline != true {
            updatedValue.append(newline)
        }
        updatedValue.append(pattern)
        updatedValue.append(newline)
        return updatedValue
    }
}

public struct StatusItem: Codable, Hashable, Identifiable, Sendable {
    public var id: String { relativePath }
    public var relativePath: String
    public var absolutePath: URL
    public var nodeKind: NodeKind
    public var workingCopyStatus: WorkingCopyStatus
    public var propertyStatus: WorkingCopyStatus
    public var remoteStatus: RemoteStatus
    public var revision: Int?
    public var copied: Bool
    public var switched: Bool
    public var locked: Bool
    public var treeConflicted: Bool
    public var changelist: String?
    public var externalRootID: UUID?
    public var lock: LockRecord?

    public init(
        relativePath: String,
        absolutePath: URL,
        nodeKind: NodeKind = .unknown,
        workingCopyStatus: WorkingCopyStatus,
        propertyStatus: WorkingCopyStatus = .none,
        remoteStatus: RemoteStatus = .none,
        revision: Int? = nil,
        copied: Bool = false,
        switched: Bool = false,
        locked: Bool = false,
        treeConflicted: Bool = false,
        changelist: String? = nil,
        externalRootID: UUID? = nil,
        lock: LockRecord? = nil
    ) {
        self.relativePath = relativePath
        self.absolutePath = absolutePath
        self.nodeKind = nodeKind
        self.workingCopyStatus = workingCopyStatus
        self.propertyStatus = propertyStatus
        self.remoteStatus = remoteStatus
        self.revision = revision
        self.copied = copied
        self.switched = switched
        self.locked = locked
        self.treeConflicted = treeConflicted
        self.changelist = changelist
        self.externalRootID = externalRootID
        self.lock = lock
    }

    public var isCommitEligible: Bool {
        guard !treeConflicted,
              workingCopyStatus != .conflicted,
              propertyStatus != .conflicted else { return false }

        return workingCopyStatus.isCommitChange || propertyStatus.isCommitChange
    }

    public var isStageable: Bool {
        isCommitEligible || (
            workingCopyStatus == .unversioned
                && !treeConflicted
                && propertyStatus != .conflicted
        )
    }
}

private extension WorkingCopyStatus {
    var isCommitChange: Bool {
        switch self {
        case .modified, .added, .deleted, .replaced, .merged:
            true
        default:
            false
        }
    }
}

public struct WorkingCopyInfo: Codable, Hashable, Sendable {
    public var path: URL
    public var workingCopyRoot: URL
    public var url: URL
    public var repositoryRootURL: URL
    public var repositoryUUID: String
    public var relativeURL: String?
    public var revision: Int
    public var nodeKind: NodeKind

    public init(
        path: URL,
        workingCopyRoot: URL,
        url: URL,
        repositoryRootURL: URL,
        repositoryUUID: String,
        relativeURL: String?,
        revision: Int,
        nodeKind: NodeKind
    ) {
        self.path = path
        self.workingCopyRoot = workingCopyRoot
        self.url = url
        self.repositoryRootURL = repositoryRootURL
        self.repositoryUUID = repositoryUUID
        self.relativeURL = relativeURL
        self.revision = revision
        self.nodeKind = nodeKind
    }
}

public enum ChangedPathAction: String, Codable, Sendable {
    case added = "A"
    case deleted = "D"
    case modified = "M"
    case replaced = "R"
    case unknown = "?"
}

public struct ChangedPath: Codable, Hashable, Identifiable, Sendable {
    public var id: String { "\(action.rawValue):\(path)" }
    public var path: String
    public var action: ChangedPathAction
    public var nodeKind: NodeKind
    public var copyFromPath: String?
    public var copyFromRevision: Int?

    public init(path: String, action: ChangedPathAction, nodeKind: NodeKind = .unknown, copyFromPath: String? = nil, copyFromRevision: Int? = nil) {
        self.path = path
        self.action = action
        self.nodeKind = nodeKind
        self.copyFromPath = copyFromPath
        self.copyFromRevision = copyFromRevision
    }
}

public struct RevisionRecord: Codable, Hashable, Identifiable, Sendable {
    public var id: Int { revision }
    public var revision: Int
    public var author: String?
    public var timestampUTC: Date?
    public var message: String
    public var changedPaths: [ChangedPath]

    public init(revision: Int, author: String?, timestampUTC: Date?, message: String, changedPaths: [ChangedPath] = []) {
        self.revision = revision
        self.author = author
        self.timestampUTC = timestampUTC
        self.message = message
        self.changedPaths = changedPaths
    }
}

public struct RepositoryEntry: Codable, Hashable, Identifiable, Sendable {
    public var id: String { url.absoluteString }
    public var name: String
    public var url: URL
    public var kind: NodeKind
    public var size: Int64?
    public var revision: Int?
    public var author: String?
    public var committedAt: Date?

    public init(name: String, url: URL, kind: NodeKind, size: Int64? = nil, revision: Int? = nil, author: String? = nil, committedAt: Date? = nil) {
        self.name = name
        self.url = url
        self.kind = kind
        self.size = size
        self.revision = revision
        self.author = author
        self.committedAt = committedAt
    }
}

public struct BlameLine: Codable, Hashable, Identifiable, Sendable {
    public var id: Int { lineNumber }
    public var lineNumber: Int
    public var revision: Int?
    public var author: String?
    public var timestampUTC: Date?
    public var content: String?

    public init(lineNumber: Int, revision: Int? = nil, author: String? = nil, timestampUTC: Date? = nil, content: String? = nil) {
        self.lineNumber = lineNumber
        self.revision = revision
        self.author = author
        self.timestampUTC = timestampUTC
        self.content = content
    }
}

public struct CommitDraft: Codable, Hashable, Sendable {
    public var projectID: UUID
    public var message: String
    public var selectedRelativePaths: Set<String>
    public var updatedAt: Date

    public init(projectID: UUID, message: String = "", selectedRelativePaths: Set<String> = [], updatedAt: Date = .now) {
        self.projectID = projectID
        self.message = message
        self.selectedRelativePaths = selectedRelativePaths
        self.updatedAt = updatedAt
    }
}
