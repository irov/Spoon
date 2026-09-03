import Foundation

public enum SVNOperationClass: String, Codable, Sendable {
    case workingCopyRead
    case workingCopyWrite
    case repositoryRead
    case repositoryWrite
}

public enum SVNOperation: String, Codable, CaseIterable, Sendable {
    case capabilityProbe
    case info
    case status
    case checkout
    case update
    case commit
    case add
    case delete
    case move
    case revert
    case cleanup
    case resolve
    case log
    case diff
    case list
    case cat
    case export
    case blame
    case proplist
    case propget
    case propset
    case propdel
    case changelist
    case lock
    case unlock
    case copy
    case mkdir
    case switchWorkingCopy
    case merge
}

public enum SVNTaskState: String, Codable, Sendable {
    case queued
    case running
    case succeeded
    case failed
    case cancelled
}

public enum SVNTaskOutputKind: String, Codable, Sendable {
    case command
    case standardOutput
    case standardError
    case warning
    case progress
    case authentication
    case system
}

public struct SVNTaskOutputLine: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let kind: SVNTaskOutputKind
    public let text: String

    public init(
        id: UUID = UUID(),
        timestamp: Date = .now,
        kind: SVNTaskOutputKind,
        text: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.text = text
    }
}

public struct SVNErrorCode: Codable, Hashable, Sendable, CustomStringConvertible {
    public var value: String
    public var description: String { value }

    public init(_ value: String) {
        self.value = value
    }
}

public struct TaskRecord: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var projectID: UUID?
    public var operation: SVNOperation
    public var targets: [String]
    public var state: SVNTaskState
    public var createdAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    public var exitCode: Int32?
    public var terminationSignal: Int32?
    public var svnErrorCodes: [SVNErrorCode]
    public var sanitizedCommand: String
    public var logReference: URL?
    public var summary: String?
    /// Optional so task records written by older Spoon builds remain decodable.
    public var outputLines: [SVNTaskOutputLine]?

    public init(
        id: UUID = UUID(),
        projectID: UUID?,
        operation: SVNOperation,
        targets: [String],
        state: SVNTaskState = .queued,
        createdAt: Date = .now,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        exitCode: Int32? = nil,
        terminationSignal: Int32? = nil,
        svnErrorCodes: [SVNErrorCode] = [],
        sanitizedCommand: String,
        logReference: URL? = nil,
        summary: String? = nil,
        outputLines: [SVNTaskOutputLine]? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.operation = operation
        self.targets = targets
        self.state = state
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.exitCode = exitCode
        self.terminationSignal = terminationSignal
        self.svnErrorCodes = svnErrorCodes
        self.sanitizedCommand = sanitizedCommand
        self.logReference = logReference
        self.summary = summary
        self.outputLines = outputLines
    }

    public mutating func appendOutput(
        kind: SVNTaskOutputKind,
        text: String,
        maximumLineCount: Int = 500
    ) {
        let trimmed = text.trimmingCharacters(in: .newlines)
        guard !trimmed.isEmpty, maximumLineCount > 0 else { return }

        let maximumCharacters = 8_000
        let rendered: String
        if trimmed.count > maximumCharacters {
            rendered = String(trimmed.prefix(maximumCharacters)) + "…"
        } else {
            rendered = trimmed
        }

        var lines = outputLines ?? []
        lines.append(SVNTaskOutputLine(kind: kind, text: rendered))
        if lines.count > maximumLineCount {
            lines.removeFirst(lines.count - maximumLineCount)
        }
        outputLines = lines
    }
}

public enum ConflictKind: String, Codable, Sendable {
    case text
    case property
    case tree
}

public enum ConflictResolution: String, Codable, CaseIterable, Sendable {
    case base
    case working
    case mineConflict = "mine-conflict"
    case theirsConflict = "theirs-conflict"
    case mineFull = "mine-full"
    case theirsFull = "theirs-full"
    case merged
}

public struct ConflictRecord: Codable, Hashable, Identifiable, Sendable {
    public var id: String { "\(kind.rawValue):\(path.path)" }
    public var path: URL
    public var kind: ConflictKind
    public var localAction: String?
    public var incomingAction: String?
    public var baseFile: URL?
    public var mineFile: URL?
    public var theirsFile: URL?

    public init(path: URL, kind: ConflictKind, localAction: String? = nil, incomingAction: String? = nil, baseFile: URL? = nil, mineFile: URL? = nil, theirsFile: URL? = nil) {
        self.path = path
        self.kind = kind
        self.localAction = localAction
        self.incomingAction = incomingAction
        self.baseFile = baseFile
        self.mineFile = mineFile
        self.theirsFile = theirsFile
    }
}

public struct SVNCapabilitySet: Codable, Hashable, Sendable {
    public var version: String
    public var architecture: String
    public var repositoryAccessModules: Set<String>
    public var credentialProviders: Set<String>
    public var supportsSearch: Bool
    public var supportsShowItem: Bool
    public var isBundled: Bool
    public var signatureValid: Bool
    public var checksumsValid: Bool
    public var openSSHVersion: String?

    public init(
        version: String,
        architecture: String,
        repositoryAccessModules: Set<String> = [],
        credentialProviders: Set<String> = [],
        supportsSearch: Bool = true,
        supportsShowItem: Bool = true,
        isBundled: Bool = false,
        signatureValid: Bool = false,
        checksumsValid: Bool = false,
        openSSHVersion: String? = nil
    ) {
        self.version = version
        self.architecture = architecture
        self.repositoryAccessModules = repositoryAccessModules
        self.credentialProviders = credentialProviders
        self.supportsSearch = supportsSearch
        self.supportsShowItem = supportsShowItem
        self.isBundled = isBundled
        self.signatureValid = signatureValid
        self.checksumsValid = checksumsValid
        self.openSSHVersion = openSSHVersion
    }
}

public struct SVNAuthenticationChallenge: Sendable {
    public enum Kind: Sendable {
        case credentials
        case serverTrust(failures: Set<String>)
    }

    public var kind: Kind
    public var host: String
    public var realm: String?
    public var message: String
    public var previousAttemptFailed: Bool

    public init(kind: Kind, host: String, realm: String?, message: String, previousAttemptFailed: Bool = false) {
        self.kind = kind
        self.host = host
        self.realm = realm
        self.message = message
        self.previousAttemptFailed = previousAttemptFailed
    }
}

public struct SVNAuthenticationResponse: Sendable {
    public var username: String?
    public var password: String?
    public var saveInKeychain: Bool
    public var acceptedServerFailures: Set<String>

    public init(
        username: String? = nil,
        password: String? = nil,
        saveInKeychain: Bool = false,
        acceptedServerFailures: Set<String> = []
    ) {
        self.username = username
        self.password = password
        self.saveInKeychain = saveInKeychain
        self.acceptedServerFailures = acceptedServerFailures
    }
}
