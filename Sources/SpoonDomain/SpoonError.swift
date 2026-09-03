import Foundation

public enum SpoonRecoveryAction: Sendable, Equatable {
    case cleanupWorkingCopy
    case cleanupAndRetryUpdate
}

public struct SpoonError: Error, LocalizedError, Sendable {
    public var title: String
    public var explanation: String
    public var operation: SVNOperation?
    public var svnCodes: [SVNErrorCode]
    public var exitCode: Int32?
    public var terminationSignal: Int32?
    public var recoverySuggestion: String?
    public var diagnosticDetails: String?

    public init(
        title: String,
        explanation: String,
        operation: SVNOperation? = nil,
        svnCodes: [SVNErrorCode] = [],
        exitCode: Int32? = nil,
        terminationSignal: Int32? = nil,
        recoverySuggestion: String? = nil,
        diagnosticDetails: String? = nil
    ) {
        self.title = title
        self.explanation = explanation
        self.operation = operation
        self.svnCodes = svnCodes
        self.exitCode = exitCode
        self.terminationSignal = terminationSignal
        self.recoverySuggestion = recoverySuggestion
        self.diagnosticDetails = diagnosticDetails
    }

    public var errorDescription: String? { title }
    public var failureReason: String? { explanation }

    public var recoveryAction: SpoonRecoveryAction? {
        guard operation != .cleanup,
              svnCodes.contains(SVNErrorCode("E155004")) else {
            return nil
        }
        return operation == .update ? .cleanupAndRetryUpdate : .cleanupWorkingCopy
    }
}
