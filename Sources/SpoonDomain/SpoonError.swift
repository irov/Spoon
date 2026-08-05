import Foundation

public struct SpoonError: Error, LocalizedError, Sendable {
    public var title: String
    public var explanation: String
    public var operation: SVNOperation?
    public var svnCodes: [SVNErrorCode]
    public var recoverySuggestion: String?
    public var diagnosticDetails: String?

    public init(
        title: String,
        explanation: String,
        operation: SVNOperation? = nil,
        svnCodes: [SVNErrorCode] = [],
        recoverySuggestion: String? = nil,
        diagnosticDetails: String? = nil
    ) {
        self.title = title
        self.explanation = explanation
        self.operation = operation
        self.svnCodes = svnCodes
        self.recoverySuggestion = recoverySuggestion
        self.diagnosticDetails = diagnosticDetails
    }

    public var errorDescription: String? { title }
    public var failureReason: String? { explanation }
}
