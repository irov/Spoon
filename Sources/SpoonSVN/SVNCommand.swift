import Foundation
import SpoonDomain
import SpoonSecurity

public struct SVNCommandDescriptor<Output: Sendable>: Sendable {
    public var executable: URL
    public var arguments: [String]
    public var workingDirectory: URL?
    public var environment: [String: String]
    public var standardInput: Data?
    public var securityScopedBookmark: Data?
    public var operation: SVNOperation
    public var operationClass: SVNOperationClass
    public var targets: [String]
    public var retainedResources: [SecureTemporaryFile]
    public var parser: @Sendable (Data, Data) throws -> Output

    public init(
        executable: URL,
        arguments: [String],
        workingDirectory: URL? = nil,
        environment: [String: String] = SVNCommandDescriptor.stableEnvironment,
        standardInput: Data? = nil,
        securityScopedBookmark: Data? = nil,
        operation: SVNOperation,
        operationClass: SVNOperationClass,
        targets: [String] = [],
        retainedResources: [SecureTemporaryFile] = [],
        parser: @escaping @Sendable (Data, Data) throws -> Output
    ) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.standardInput = standardInput
        self.securityScopedBookmark = securityScopedBookmark
        self.operation = operation
        self.operationClass = operationClass
        self.targets = targets
        self.retainedResources = retainedResources
        self.parser = parser
    }

    public func withSecurityScopedBookmark(_ bookmark: Data?) -> Self {
        var copy = self
        copy.securityScopedBookmark = bookmark
        return copy
    }

    public func applying(authentication response: SVNAuthenticationResponse) -> Self {
        var copy = self
        var arguments = arguments
        Self.removeGlobalOption("--username", takesValue: true, from: &arguments)
        Self.removeGlobalOption("--password-from-stdin", takesValue: false, from: &arguments)
        Self.removeGlobalOption("--trust-server-cert-failures", takesValue: true, from: &arguments)

        var options: [String] = []
        if let username = response.username, !username.isEmpty { options += ["--username", username] }
        if let password = response.password {
            options.append("--password-from-stdin")
            copy.standardInput = Data((password + "\n").utf8)
        }
        if !response.acceptedServerFailures.isEmpty {
            options += ["--trust-server-cert-failures", response.acceptedServerFailures.sorted().joined(separator: ",")]
        }
        arguments.insert(contentsOf: options, at: min(1, arguments.count))
        copy.arguments = arguments
        return copy
    }

    private static func removeGlobalOption(_ option: String, takesValue: Bool, from arguments: inout [String]) {
        while let index = arguments.firstIndex(of: option) {
            arguments.remove(at: index)
            if takesValue, index < arguments.count { arguments.remove(at: index) }
        }
    }

    public var sanitizedCommand: String {
        Redactor.command(executable: executable, arguments: arguments)
    }

    public static var stableEnvironment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "en_US.UTF-8"
        environment["LANG"] = "en_US.UTF-8"
        environment["SVN_EDITOR"] = "/usr/bin/false"
        environment["SVN_MERGE"] = "/usr/bin/false"
        return environment
    }
}

public enum SVNCommandEvent: Sendable {
    case started(processIdentifier: Int32)
    case stdout(String)
    case stderr(String)
    case warning(String)
    case progress(String)
    case authenticationPrompt(String)
}

public struct SVNCommandResult<Output: Sendable>: Sendable {
    public var taskID: UUID
    public var output: Output
    public var exitCode: Int32
    public var terminationSignal: Int32?
    public var stdout: Data
    public var stderr: Data
    public var svnErrorCodes: [SVNErrorCode]
    public var wasCancelled: Bool
    public var duration: Duration

    public init(
        taskID: UUID,
        output: Output,
        exitCode: Int32,
        terminationSignal: Int32?,
        stdout: Data,
        stderr: Data,
        svnErrorCodes: [SVNErrorCode],
        wasCancelled: Bool,
        duration: Duration
    ) {
        self.taskID = taskID
        self.output = output
        self.exitCode = exitCode
        self.terminationSignal = terminationSignal
        self.stdout = stdout
        self.stderr = stderr
        self.svnErrorCodes = svnErrorCodes
        self.wasCancelled = wasCancelled
        self.duration = duration
    }
}

public struct SVNExecution<Output: Sendable>: Sendable {
    public let taskID: UUID
    public let events: AsyncStream<SVNCommandEvent>
    public let result: Task<SVNCommandResult<Output>, Error>

    public init(taskID: UUID, events: AsyncStream<SVNCommandEvent>, result: Task<SVNCommandResult<Output>, Error>) {
        self.taskID = taskID
        self.events = events
        self.result = result
    }
}

public enum SVNExecutableLocator {
    public static func bundledSVN(bundle: Bundle = .main) -> URL {
        if let bundled = bundle.url(forAuxiliaryExecutable: "svn") {
            return bundled
        }
        if let resource = bundle.url(forResource: "svn", withExtension: nil, subdirectory: "Helpers") {
            return resource
        }
        let helper = bundle.bundleURL.appendingPathComponent("Contents/Helpers/svn")
        if FileManager.default.isExecutableFile(atPath: helper.path) {
            return helper
        }
        #if DEBUG
        return URL(fileURLWithPath: "/usr/bin/svn")
        #else
        return helper
        #endif
    }
}

public enum SVNErrorExtractor {
    public static func codes(in text: String) -> [SVNErrorCode] {
        guard let expression = try? NSRegularExpression(pattern: #"svn:\s+(E\d{6})"#) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = expression.matches(in: text, range: range)
        var seen = Set<String>()
        return matches.compactMap { match in
            guard match.numberOfRanges > 1,
                  let codeRange = Range(match.range(at: 1), in: text) else { return nil }
            let code = String(text[codeRange])
            return seen.insert(code).inserted ? SVNErrorCode(code) : nil
        }
    }
}
